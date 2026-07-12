#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/tg-ai-spam-bot}"
SERVICE_NAME="${SERVICE_NAME:-tg-ai-spam-bot}"
CONFIG_FILE="$APP_DIR/config.env"
PYTHON_BIN="${PYTHON_BIN:-python3}"
ACTION="${1:-install}"

DEFAULT_BOT_TOKEN="${BOT_TOKEN:-}"
DEFAULT_OWNER_IDS="${OWNER_IDS:-5390861579}"
DEFAULT_AI_BASE_URL="${AI_BASE_URL:-http://127.0.0.1:8321/v1}"
DEFAULT_AI_API_KEY="${AI_API_KEY:-}"
DEFAULT_AI_MODEL="${AI_MODEL:-xai.grok-4.3}"
DEFAULT_UNAUTHORIZED_POLICY="${UNAUTHORIZED_POLICY:-leave}"
DEFAULT_DEFAULT_MODE="${DEFAULT_MODE:-normal}"

need_root() {
  if [[ "$(id -u)" != "0" ]]; then
    echo "请用 root 运行：sudo bash $0 $ACTION" >&2
    exit 1
  fi
}

prompt_value() {
  local name="$1" default="$2" secret="${3:-0}" value
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    printf '%s' "$default"
    return
  fi
  if [[ "$secret" == "1" ]]; then
    read -r -s -p "$name [$default]: " value || true
    echo >&2
  else
    read -r -p "$name [$default]: " value || true
  fi
  printf '%s' "${value:-$default}"
}

write_config() {
  mkdir -p "$APP_DIR"
  local bot_token owner_ids ai_base ai_key ai_model unauthorized mode
  bot_token="$(prompt_value BOT_TOKEN "$DEFAULT_BOT_TOKEN" 1)"
  owner_ids="$(prompt_value OWNER_IDS "$DEFAULT_OWNER_IDS")"
  ai_base="$(prompt_value AI_BASE_URL "$DEFAULT_AI_BASE_URL")"
  ai_key="$(prompt_value AI_API_KEY "$DEFAULT_AI_API_KEY" 1)"
  ai_model="$(prompt_value AI_MODEL "$DEFAULT_AI_MODEL")"
  unauthorized="$(prompt_value UNAUTHORIZED_POLICY "$DEFAULT_UNAUTHORIZED_POLICY")"
  mode="$(prompt_value DEFAULT_MODE "$DEFAULT_DEFAULT_MODE")"
  cat > "$CONFIG_FILE" <<EOF_CFG
# Telegram AI 群反垃圾机器人配置
# 重新配置：bash /root/install_tg_ai_spam_bot.sh configure
# 重启服务：systemctl restart $SERVICE_NAME

BOT_TOKEN=$bot_token
OWNER_IDS=$owner_ids

# OpenAI 兼容 AI API，可换成任何 /v1/chat/completions 兼容接口
AI_BASE_URL=$ai_base
AI_API_KEY=$ai_key
AI_MODEL=$ai_model
AI_TIMEOUT=45

# 未授权群策略：leave=自动退出；silent=留群但不工作
UNAUTHORIZED_POLICY=$unauthorized
# 默认群模式：normal/strict/silent
DEFAULT_MODE=$mode

# AI 成本保护
GROUP_AI_PER_MINUTE=30
USER_MSG_PER_MINUTE=10
GLOBAL_AI_PER_MINUTE=100
NORMAL_CACHE_SECONDS=600
SPAM_CACHE_SECONDS=86400

# 处罚策略
HIGH_RISK_BAN_MINUTES=1440
MEDIUM_RISK_MUTE_MINUTES=60
WARN_LIMIT_MUTE=2
WARN_LIMIT_BAN=4
SELF_UNBAN_ENABLED=true
SELF_UNBAN_COOLDOWN_MINUTES=10
SELF_UNBAN_MAX_PER_DAY=3
SELF_UNBAN_OBSERVE_HOURS=24
# 广告处理提示保留秒数；0=不自动删除
NOTICE_DELETE_SECONDS=120
# 个人简介检查缓存秒数，避免每条消息都重复查询用户资料
PROFILE_BIO_CACHE_SECONDS=21600

# 管理员/白名单跳过审核
SKIP_ADMINS=true
LOG_LEVEL=INFO
EOF_CFG
  chmod 600 "$CONFIG_FILE"
}

write_app() {
  mkdir -p "$APP_DIR/data" "$APP_DIR/logs"
  cat > "$APP_DIR/requirements.txt" <<'EOF_REQ'
python-telegram-bot[job-queue]==21.11.1
httpx==0.28.1
python-dotenv==1.0.1
EOF_REQ

  cat > "$APP_DIR/bot.py" <<'EOF_PY'
#!/usr/bin/env python3
import asyncio
import hashlib
from html.parser import HTMLParser
import json
import logging
import os
import re
import sqlite3
import time
import unicodedata
from collections import defaultdict, deque
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Optional

import httpx
from dotenv import load_dotenv
from telegram import Chat, ChatMember, ChatPermissions, InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.constants import ChatMemberStatus, ChatType, ParseMode
from telegram.error import BadRequest, Forbidden, TelegramError
from telegram.ext import Application, CallbackQueryHandler, CommandHandler, ContextTypes, MessageHandler, filters

APP_DIR = os.path.dirname(os.path.abspath(__file__))
load_dotenv(os.path.join(APP_DIR, "config.env"))

BOT_TOKEN = os.getenv("BOT_TOKEN", "").strip()
OWNER_IDS = {int(x) for x in re.split(r"[,\s]+", os.getenv("OWNER_IDS", "")) if x.strip().isdigit()}
AI_BASE_URL = os.getenv("AI_BASE_URL", "http://127.0.0.1:8321/v1").rstrip("/")
AI_API_KEY = os.getenv("AI_API_KEY", "")
AI_MODEL = os.getenv("AI_MODEL", "xai.grok-4.3")
AI_TIMEOUT = float(os.getenv("AI_TIMEOUT", "45"))
UNAUTHORIZED_POLICY = os.getenv("UNAUTHORIZED_POLICY", "leave").lower()
DEFAULT_MODE = os.getenv("DEFAULT_MODE", "normal").lower()
GROUP_AI_PER_MINUTE = int(os.getenv("GROUP_AI_PER_MINUTE", "30"))
USER_MSG_PER_MINUTE = int(os.getenv("USER_MSG_PER_MINUTE", "10"))
GLOBAL_AI_PER_MINUTE = int(os.getenv("GLOBAL_AI_PER_MINUTE", "100"))
NORMAL_CACHE_SECONDS = int(os.getenv("NORMAL_CACHE_SECONDS", "600"))
SPAM_CACHE_SECONDS = int(os.getenv("SPAM_CACHE_SECONDS", "86400"))
HIGH_RISK_BAN_MINUTES = int(os.getenv("HIGH_RISK_BAN_MINUTES", "1440"))
MEDIUM_RISK_MUTE_MINUTES = int(os.getenv("MEDIUM_RISK_MUTE_MINUTES", "60"))
WARN_LIMIT_MUTE = int(os.getenv("WARN_LIMIT_MUTE", "2"))
WARN_LIMIT_BAN = int(os.getenv("WARN_LIMIT_BAN", "4"))
SELF_UNBAN_ENABLED = os.getenv("SELF_UNBAN_ENABLED", "true").lower() == "true"
SELF_UNBAN_COOLDOWN_MINUTES = int(os.getenv("SELF_UNBAN_COOLDOWN_MINUTES", "10"))
SELF_UNBAN_MAX_PER_DAY = int(os.getenv("SELF_UNBAN_MAX_PER_DAY", "3"))
SELF_UNBAN_OBSERVE_HOURS = int(os.getenv("SELF_UNBAN_OBSERVE_HOURS", "24"))
NOTICE_DELETE_SECONDS = int(os.getenv("NOTICE_DELETE_SECONDS", "120"))
PROFILE_BIO_CACHE_SECONDS = int(os.getenv("PROFILE_BIO_CACHE_SECONDS", "21600"))
SKIP_ADMINS = os.getenv("SKIP_ADMINS", "true").lower() == "true"

DB_PATH = os.path.join(APP_DIR, "data", "bot.db")
LOG_PATH = os.path.join(APP_DIR, "logs", "bot.log")
os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
logging.basicConfig(
    level=getattr(logging, os.getenv("LOG_LEVEL", "INFO").upper(), logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    handlers=[logging.FileHandler(LOG_PATH), logging.StreamHandler()],
)
log = logging.getLogger("tg-ai-spam-bot")

if not BOT_TOKEN:
    raise SystemExit("BOT_TOKEN 未配置")
if not OWNER_IDS:
    raise SystemExit("OWNER_IDS 未配置")

@dataclass
class AiResult:
    is_spam: bool = False
    risk: str = "low"
    category: str = "normal"
    confidence: float = 0.0
    reason: str = ""
    action: str = "allow"

class Store:
    def __init__(self, path: str):
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.row_factory = sqlite3.Row
        self.lock = asyncio.Lock()
        self.init()

    def init(self):
        c = self.conn.cursor()
        c.executescript('''
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS groups(
          chat_id INTEGER PRIMARY KEY, title TEXT, enabled INTEGER DEFAULT 1,
          mode TEXT DEFAULT 'normal', created_at INTEGER, updated_at INTEGER
        );
        CREATE TABLE IF NOT EXISTS whitelist(
          chat_id INTEGER, user_id INTEGER, note TEXT, created_at INTEGER,
          PRIMARY KEY(chat_id, user_id)
        );
        CREATE TABLE IF NOT EXISTS warnings(
          chat_id INTEGER, user_id INTEGER, count INTEGER DEFAULT 0,
          updated_at INTEGER, PRIMARY KEY(chat_id, user_id)
        );
        CREATE TABLE IF NOT EXISTS bans(
          id INTEGER PRIMARY KEY AUTOINCREMENT, chat_id INTEGER, chat_title TEXT,
          user_id INTEGER, username TEXT, full_name TEXT, operator_id INTEGER,
          reason TEXT, risk TEXT, source TEXT, started_at INTEGER, until_at INTEGER,
          status TEXT DEFAULT 'active', self_unban_allowed INTEGER DEFAULT 0,
          appeal_count INTEGER DEFAULT 0, last_appeal_at INTEGER DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS logs(
          id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, chat_id INTEGER, chat_title TEXT,
          user_id INTEGER, username TEXT, text TEXT, ai_json TEXT, action TEXT, ok INTEGER, error TEXT
        );
        CREATE TABLE IF NOT EXISTS cache(
          hash TEXT PRIMARY KEY, result_json TEXT, expires_at INTEGER
        );
        CREATE TABLE IF NOT EXISTS observe(
          chat_id INTEGER, user_id INTEGER, until_at INTEGER,
          PRIMARY KEY(chat_id, user_id)
        );
        ''')
        self.conn.commit()

    async def execute(self, sql: str, params=()):
        async with self.lock:
            cur = self.conn.execute(sql, params)
            self.conn.commit()
            return cur

    async def one(self, sql: str, params=()):
        async with self.lock:
            return self.conn.execute(sql, params).fetchone()

    async def all(self, sql: str, params=()):
        async with self.lock:
            return self.conn.execute(sql, params).fetchall()

store = Store(DB_PATH)
profile_bio_cache: dict[int, tuple[int, str]] = {}
user_windows: dict[tuple[int, int], deque] = defaultdict(deque)
group_ai_windows: dict[int, deque] = defaultdict(deque)
global_ai_window: deque = deque()
DEFAULT_USER_PERMISSIONS = ChatPermissions(
    can_send_messages=True,
    can_send_audios=True,
    can_send_documents=True,
    can_send_photos=True,
    can_send_videos=True,
    can_send_video_notes=True,
    can_send_voice_notes=True,
    can_send_polls=True,
    can_send_other_messages=True,
    can_add_web_page_previews=True,
    can_invite_users=True,
)


def now_ts() -> int:
    return int(time.time())

def until_datetime(minutes: int):
    return datetime.now(timezone.utc) + timedelta(minutes=minutes)

def parse_duration(s: Optional[str]) -> Optional[int]:
    if not s:
        return None
    s = s.strip().lower()
    if s in {"forever", "permanent", "永久", "永久封禁"}:
        return None
    m = re.fullmatch(r"(\d+)([mhd天小时分钟]?)", s)
    if not m:
        return None
    n = int(m.group(1)); unit = m.group(2)
    if unit in {"h", "小时"}: return n * 60
    if unit in {"d", "天"}: return n * 1440
    return n

def display_user(u) -> str:
    name = " ".join(x for x in [u.first_name, u.last_name] if x)
    return name or u.username or str(u.id)


async def user_profile_bio(user_id: int, context: ContextTypes.DEFAULT_TYPE) -> str:
    """Read a sender's public Telegram profile bio with a bounded in-memory cache."""
    cached = profile_bio_cache.get(user_id)
    if cached and cached[0] > now_ts():
        return cached[1]
    bio = ""
    try:
        profile = await context.bot.get_chat(user_id)
        bio = (getattr(profile, "bio", None) or "").strip()
    except TelegramError as e:
        log.debug("profile bio unavailable user=%s: %s", user_id, e)
    profile_bio_cache[user_id] = (now_ts() + PROFILE_BIO_CACHE_SECONDS, bio)
    return bio

def text_hash(text: str) -> str:
    return hashlib.sha256(text.strip().lower().encode("utf-8", "ignore")).hexdigest()

async def is_owner(user_id: int) -> bool:
    return user_id in OWNER_IDS

def is_sender_chat_message(msg) -> bool:
    sender_chat = getattr(msg, "sender_chat", None)
    return bool(sender_chat and sender_chat.type in {ChatType.CHANNEL, ChatType.GROUP, ChatType.SUPERGROUP})

def is_group_skin_command(update: Update) -> bool:
    msg = update.effective_message
    chat = update.effective_chat
    if not msg or not chat or chat.type not in {ChatType.GROUP, ChatType.SUPERGROUP}:
        return False
    sender_chat = getattr(msg, "sender_chat", None)
    if not sender_chat:
        return False
    # Telegram anonymous admin posts use sender_chat == current group; linked-channel
    # posts may use sender_chat.type == channel. Treat these as admin "skin" for /enable only.
    return sender_chat.id == chat.id or sender_chat.type == ChatType.CHANNEL

async def is_group_admin(chat_id: int, user_id: int, context: ContextTypes.DEFAULT_TYPE) -> bool:
    if user_id in OWNER_IDS:
        return True
    try:
        member = await context.bot.get_chat_member(chat_id, user_id)
        return member.status in {ChatMemberStatus.ADMINISTRATOR, ChatMemberStatus.OWNER}
    except TelegramError:
        return False

async def bot_permissions(chat_id: int, context: ContextTypes.DEFAULT_TYPE) -> dict[str, bool]:
    me = await context.bot.get_me()
    try:
        m = await context.bot.get_chat_member(chat_id, me.id)
        return {
            "is_admin": m.status in {ChatMemberStatus.ADMINISTRATOR, ChatMemberStatus.OWNER},
            "can_delete": bool(getattr(m, "can_delete_messages", False)),
            "can_restrict": bool(getattr(m, "can_restrict_members", False)),
        }
    except TelegramError:
        return {"is_admin": False, "can_delete": False, "can_restrict": False}

async def group_row(chat_id: int):
    return await store.one("SELECT * FROM groups WHERE chat_id=?", (chat_id,))

async def is_authorized(chat: Chat) -> bool:
    row = await group_row(chat.id)
    return bool(row and row["enabled"])

async def ensure_authorized_or_leave(update: Update, context: ContextTypes.DEFAULT_TYPE) -> bool:
    chat = update.effective_chat
    if not chat or chat.type not in {ChatType.GROUP, ChatType.SUPERGROUP}:
        return True
    if await is_authorized(chat):
        return True
    user = update.effective_user
    msg = update.effective_message
    if msg and msg.text and msg.text.startswith(("/enable", "/start")):
        if (user and user.id in OWNER_IDS) or is_group_skin_command(update):
            return True
    if UNAUTHORIZED_POLICY == "leave":
        try:
            await context.bot.send_message(chat.id, "本机器人未被授权在此群使用，将自动退出。请 owner 在需要的群里使用 /enable。")
        except TelegramError:
            pass
        try:
            await context.bot.leave_chat(chat.id)
        except TelegramError as e:
            log.warning("leave unauthorized chat failed chat=%s err=%s", chat.id, e)
    return False

async def notify_owner(context: ContextTypes.DEFAULT_TYPE, text: str):
    for oid in OWNER_IDS:
        try:
            await context.bot.send_message(oid, text[:3900])
        except TelegramError as e:
            log.warning("notify owner failed owner=%s err=%s", oid, e)

async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat = update.effective_chat; user = update.effective_user
    if chat.type in {ChatType.GROUP, ChatType.SUPERGROUP}:
        await update.effective_message.reply_text("群内请使用 /enable 启用，/status 查看状态。")
        return
    if user.id in OWNER_IDS:
        rows = await store.all("SELECT * FROM groups ORDER BY updated_at DESC")
        msg = ["AI 群反垃圾机器人已运行。", "", "常用命令：", "/groups - 授权群列表", "/status - 私聊查看全局状态", "群内：/enable /disable /ban 60 /unban /mode normal"]
        if rows:
            msg.append("\n已授权群：")
            for r in rows[:20]:
                msg.append(f"- {r['title']} `{r['chat_id']}` enabled={r['enabled']} mode={r['mode']}")
        await update.effective_message.reply_text("\n".join(msg), parse_mode=ParseMode.MARKDOWN)
        return
    await handle_private_appeal(update, context)

async def cmd_enable(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat = update.effective_chat; user = update.effective_user
    if chat.type not in {ChatType.GROUP, ChatType.SUPERGROUP}:
        await update.effective_message.reply_text("请在要启用的群里发送 /enable。")
        return
    if not ((user and user.id in OWNER_IDS) or is_group_skin_command(update)):
        await update.effective_message.reply_text("只有 owner，或群匿名/频道身份，可以启用本群。")
        return
    perms = await bot_permissions(chat.id, context)
    ts = now_ts()
    await store.execute("INSERT INTO groups(chat_id,title,enabled,mode,created_at,updated_at) VALUES(?,?,?,?,?,?) ON CONFLICT(chat_id) DO UPDATE SET title=excluded.title, enabled=1, updated_at=excluded.updated_at", (chat.id, chat.title or str(chat.id), 1, DEFAULT_MODE, ts, ts))
    privacy_tip = "\n提示：/status 只能检测管理权限，不能准确判断 BotFather Privacy Mode；只要机器人是群管理员，通常能收到群消息。"
    await update.effective_message.reply_text(f"已启用 AI 群反垃圾。\n模式：{DEFAULT_MODE}\n权限：删除={perms['can_delete']} 限制/封禁={perms['can_restrict']}" + privacy_tip)

async def cmd_disable(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat = update.effective_chat; user = update.effective_user
    if chat.type not in {ChatType.GROUP, ChatType.SUPERGROUP}: return
    if user.id not in OWNER_IDS:
        await update.effective_message.reply_text("只有 owner 可以停用本群。")
        return
    await store.execute("UPDATE groups SET enabled=0, updated_at=? WHERE chat_id=?", (now_ts(), chat.id))
    await update.effective_message.reply_text("已停用本群 AI 审核。")

async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat = update.effective_chat
    if chat.type in {ChatType.GROUP, ChatType.SUPERGROUP}:
        row = await group_row(chat.id)
        perms = await bot_permissions(chat.id, context)
        cnt = await store.one("SELECT COUNT(*) c FROM logs WHERE chat_id=? AND ts>?", (chat.id, now_ts()-86400))
        bans = await store.one("SELECT COUNT(*) c FROM bans WHERE chat_id=? AND status='active'", (chat.id,))
        await update.effective_message.reply_text(f"授权：{bool(row and row['enabled'])}\n模式：{row['mode'] if row else '-'}\n今日处理日志：{cnt['c']}\n当前活动封禁：{bans['c']}\n机器人权限：管理员={perms['is_admin']} 删除={perms['can_delete']} 限制/封禁={perms['can_restrict']}")
    else:
        if update.effective_user.id not in OWNER_IDS:
            await handle_private_appeal(update, context); return
        groups = await store.one("SELECT COUNT(*) c FROM groups WHERE enabled=1")
        logs = await store.one("SELECT COUNT(*) c FROM logs WHERE ts>?", (now_ts()-86400,))
        active = await store.one("SELECT COUNT(*) c FROM bans WHERE status='active'")
        await update.effective_message.reply_text(f"全局状态：\n授权群：{groups['c']}\n24h日志：{logs['c']}\n活动封禁：{active['c']}\nAI：{AI_BASE_URL} model={AI_MODEL}")

async def cmd_groups(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if update.effective_user.id not in OWNER_IDS: return
    rows = await store.all("SELECT * FROM groups ORDER BY updated_at DESC")
    if not rows:
        await update.effective_message.reply_text("暂无授权群。")
        return
    lines = ["授权群："]
    for r in rows:
        lines.append(f"- {r['title']} `{r['chat_id']}` enabled={r['enabled']} mode={r['mode']}")
    await update.effective_message.reply_text("\n".join(lines[:80]), parse_mode=ParseMode.MARKDOWN)

async def cmd_mode(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat = update.effective_chat; user = update.effective_user
    if chat.type not in {ChatType.GROUP, ChatType.SUPERGROUP}: return
    if not await is_group_admin(chat.id, user.id, context):
        await update.effective_message.reply_text("只有管理员可以切换模式。")
        return
    mode = context.args[0].lower() if context.args else ""
    if mode not in {"normal", "strict", "silent"}:
        await update.effective_message.reply_text("用法：/mode normal|strict|silent")
        return
    await store.execute("UPDATE groups SET mode=?, updated_at=? WHERE chat_id=?", (mode, now_ts(), chat.id))
    await update.effective_message.reply_text(f"已切换模式：{mode}")

async def get_target_from_reply(update: Update):
    msg = update.effective_message
    if msg.reply_to_message and msg.reply_to_message.from_user:
        return msg.reply_to_message.from_user
    return None

async def do_ban(chat, target, operator_id: int, minutes: Optional[int], reason: str, risk: str, source: str, context: ContextTypes.DEFAULT_TYPE, self_unban_allowed: bool):
    until = None if minutes is None else until_datetime(minutes)
    await context.bot.ban_chat_member(chat.id, target.id, until_date=until, revoke_messages=False)
    ts = now_ts(); until_ts = 0 if minutes is None else ts + minutes*60
    await store.execute("INSERT INTO bans(chat_id,chat_title,user_id,username,full_name,operator_id,reason,risk,source,started_at,until_at,status,self_unban_allowed) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", (chat.id, chat.title or str(chat.id), target.id, target.username or "", display_user(target), operator_id, reason, risk, source, ts, until_ts, "active", 1 if self_unban_allowed else 0))

async def cmd_ban(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat = update.effective_chat; user = update.effective_user
    if chat.type not in {ChatType.GROUP, ChatType.SUPERGROUP}: return
    if not await ensure_authorized_or_leave(update, context): return
    if not await is_group_admin(chat.id, user.id, context):
        await update.effective_message.reply_text("只有 owner 或群管理员可以使用 /ban。")
        return
    target = await get_target_from_reply(update)
    if not target:
        await update.effective_message.reply_text("请回复要封禁的用户消息使用：/ban 60 或 /ban 1d 或 /ban forever")
        return
    if await is_group_admin(chat.id, target.id, context):
        await update.effective_message.reply_text("不能封禁 owner/群管理员。")
        return
    minutes = parse_duration(context.args[0]) if context.args else None
    reason = "管理员手动封禁"
    try:
        await do_ban(chat, target, user.id, minutes, reason, "manual", "manual", context, self_unban_allowed=bool(minutes))
        await update.effective_message.reply_text(f"已封禁 {display_user(target)}：{'永久' if minutes is None else str(minutes)+'分钟'}")
    except TelegramError as e:
        await update.effective_message.reply_text(f"封禁失败：{e}")

async def cmd_unban(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat = update.effective_chat; user = update.effective_user
    if chat.type not in {ChatType.GROUP, ChatType.SUPERGROUP}: return
    if not await is_group_admin(chat.id, user.id, context):
        await update.effective_message.reply_text("只有 owner 或群管理员可以使用 /unban。")
        return
    target_id = None
    if update.effective_message.reply_to_message and update.effective_message.reply_to_message.from_user:
        target_id = update.effective_message.reply_to_message.from_user.id
    elif context.args and context.args[0].lstrip("-").isdigit():
        target_id = int(context.args[0])
    if not target_id:
        await update.effective_message.reply_text("用法：回复用户 /unban，或 /unban 用户数字ID")
        return
    try:
        await context.bot.unban_chat_member(chat.id, target_id, only_if_banned=True)
        await store.execute("UPDATE bans SET status='unbanned' WHERE chat_id=? AND user_id=? AND status='active'", (chat.id, target_id))
        await update.effective_message.reply_text(f"已解封用户 {target_id}")
    except TelegramError as e:
        await update.effective_message.reply_text(f"解封失败：{e}")

async def cmd_whitelist(update: Update, context: ContextTypes.DEFAULT_TYPE):
    chat = update.effective_chat; user = update.effective_user
    if chat.type not in {ChatType.GROUP, ChatType.SUPERGROUP}: return
    if not await is_group_admin(chat.id, user.id, context): return
    cmd = update.effective_message.text.split()[0].split('@')[0]
    target = await get_target_from_reply(update)
    if cmd.endswith("whitelist_add"):
        if not target:
            await update.effective_message.reply_text("请回复用户消息使用 /whitelist_add"); return
        await store.execute("INSERT OR REPLACE INTO whitelist(chat_id,user_id,note,created_at) VALUES(?,?,?,?)", (chat.id, target.id, display_user(target), now_ts()))
        await update.effective_message.reply_text(f"已加入白名单：{display_user(target)}")
    elif cmd.endswith("whitelist_del"):
        if not target:
            await update.effective_message.reply_text("请回复用户消息使用 /whitelist_del"); return
        await store.execute("DELETE FROM whitelist WHERE chat_id=? AND user_id=?", (chat.id, target.id))
        await update.effective_message.reply_text(f"已移出白名单：{display_user(target)}")
    else:
        rows = await store.all("SELECT * FROM whitelist WHERE chat_id=? ORDER BY created_at DESC LIMIT 50", (chat.id,))
        await update.effective_message.reply_text("白名单：\n" + "\n".join([f"- {r['note']} `{r['user_id']}`" for r in rows]) if rows else "白名单为空", parse_mode=ParseMode.MARKDOWN)

def _button_value(button) -> str:
    """Return a safe, human-readable description of an inline button."""
    values = [getattr(button, "text", "")]
    for attr in ("url", "login_url", "web_app", "callback_data", "switch_inline_query", "switch_inline_query_current_chat"):
        value = getattr(button, attr, None)
        if value:
            values.append(getattr(value, "url", None) or str(value))
    return " | ".join(str(x).strip() for x in values if str(x).strip())


def message_content(msg) -> str:
    """Collect text, entity URLs and inline-button targets; buttons can be the whole ad."""
    parts = [msg.text or msg.caption or ""]
    for entity in list(msg.entities or []) + list(msg.caption_entities or []):
        url = getattr(entity, "url", None)
        if url:
            parts.append(url)
    markup = getattr(msg, "reply_markup", None)
    for row in (getattr(markup, "inline_keyboard", None) or []):
        for button in row:
            value = _button_value(button)
            if value:
                parts.append(f"[按钮] {value}")
    return "\n".join(part for part in parts if part).strip()


class TelegramPostPreviewParser(HTMLParser):
    """Extract visible post text from Telegram's public embed page."""
    def __init__(self):
        super().__init__()
        self._in_text = 0
        self.parts: list[str] = []

    def handle_starttag(self, tag, attrs):
        classes = dict(attrs).get("class", "")
        if tag == "div" and "tgme_widget_message_text" in classes:
            self._in_text += 1
        elif self._in_text and tag in {"br", "p"}:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag == "div" and self._in_text:
            self._in_text -= 1

    def handle_data(self, data):
        if self._in_text:
            self.parts.append(data)


async def enrich_telegram_post_links(text: str) -> str:
    """Attach public t.me/<channel>/<post> preview text for reliable ad checks.

    Telegram delivers only the link in a chat message; its rich preview is client-side
    and is not present in Bot API Message.text. Fetching the public embed fills that
    blind spot. Failures deliberately keep the original message usable.
    """
    links = re.findall(r"https?://t\.me/([A-Za-z0-9_]{5,})/(\d+)(?:[/?#][^\s]*)?", text, re.I)
    if not links:
        return text
    previews = []
    async with httpx.AsyncClient(timeout=8, follow_redirects=True, headers={"User-Agent": "Mozilla/5.0"}) as client:
        for channel, post_id in links[:3]:
            try:
                response = await client.get(f"https://t.me/{channel}/{post_id}?embed=1&mode=tme")
                response.raise_for_status()
                parser = TelegramPostPreviewParser()
                parser.feed(response.text)
                preview = " ".join("".join(parser.parts).split())
                if preview:
                    previews.append(f"[Telegram链接预览 @{channel}/{post_id}] {preview[:2500]}")
            except (httpx.HTTPError, ValueError) as e:
                log.info("telegram link preview unavailable @%s/%s: %s", channel, post_id, e)
    return "\n".join([text, *previews]) if previews else text


def normalize_for_scan(text: str) -> str:
    # Ads commonly insert zero-width characters to evade pattern matching.
    return "".join(ch for ch in unicodedata.normalize("NFKC", text) if unicodedata.category(ch) not in {"Cf", "Cc"})


async def local_prefilter(text: str) -> Optional[AiResult]:
    t = text.strip()
    if not t:
        return AiResult(False, "low", "normal", 1.0, "空消息", "allow")
    scan = normalize_for_scan(t).lower()
    hard = ["助记词", "私聊客服", "包赔", "稳赚", "博彩", "六合彩", "裸聊", "成人视频", "空投领取", "钱包验证"]
    if any(k in scan for k in hard):
        return AiResult(True, "high", "keyword", 0.95, "命中高风险关键词", "ban")
    ad_patterns = [r"@\w*bot\b.*campaign[_-]?\w+", r"campaign[_-]?\w+", r"日入\s*\d+", r"点击一键观看", r"提取码[:：]", r"机器人[一二三四五六七八九十号]+[:：]"]
    if any(re.search(p, scan, re.I) for p in ad_patterns):
        return AiResult(True, "medium", "ad", 0.9, "命中广告特征", "delete")
    telegram_urls = re.findall(r"(?:https?://)?(?:t\.me|telegram\.me)/(?:joinchat/|\+)?[^\s|\]\)]+", scan, re.I)
    button_ad_words = r"加入.{0,3}群|进.{0,3}群|加.{0,3}群|福利.{0,3}群|资源.{0,3}群|推广|领取|点击|免费|看片|成人视频|赚钱|兼职"
    if telegram_urls and (re.search(r"(?:t\.me|telegram\.me)/(?:joinchat/|\+)", scan, re.I) or re.search(button_ad_words, scan, re.I)):
        return AiResult(True, "medium", "group_link_ad", 0.92, "按钮或消息包含引流群链接", "delete")
    url_count = len(re.findall(r"https?://|t\.me/|telegram\.me/", scan, re.I))
    if len(scan) < 12 and url_count == 0:
        return AiResult(False, "low", "normal", 0.9, "短普通文本", "allow")
    return None


async def cmd_checkad(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Admin-only manual analysis. Reply to a message; add `delete` to delete if confirmed spam."""
    chat = update.effective_chat
    operator = update.effective_user
    command = update.effective_message
    if chat.type not in {ChatType.GROUP, ChatType.SUPERGROUP}:
        await command.reply_text("请在已授权群内回复要检查的消息使用 /checkad。")
        return
    if not await ensure_authorized_or_leave(update, context):
        return
    if not await is_group_admin(chat.id, operator.id, context):
        await command.reply_text("只有群管理员可以手动识别广告。")
        return
    target = command.reply_to_message
    if not target:
        await command.reply_text("用法：回复可疑消息发送 /checkad；确认后删除用 /checkad delete。\n可检查纯按钮、按钮链接和文字/链接广告。")
        return
    content = message_content(target)
    if not content:
        await command.reply_text("该消息没有可识别的文字、链接或按钮。")
        return
    content = await enrich_telegram_post_links(content)
    try:
        result = await local_prefilter(content)
        if result is None:
            result = await call_ai(content, f"chat_id={chat.id}, title={chat.title}, manual_check=true", f"manual operator={operator.id}; target_sender={getattr(target.from_user, 'id', None)}")
        verdict = "广告/垃圾" if result.is_spam else "正常"
        reply = f"手动识别结果：{verdict}\n风险：{result.risk}\n置信度：{result.confidence:.0%}\n类型：{result.category}\n原因：{result.reason or '无'}"
        delete_requested = bool(context.args and context.args[0].lower() in {"delete", "del", "删除"})
        if delete_requested and result.is_spam and result.risk != "low" and result.confidence >= 0.60:
            try:
                await target.delete()
                reply += "\n已按管理员指令删除原消息。"
            except TelegramError as e:
                reply += f"\n识别为广告，但删除失败：{e}"
        elif delete_requested:
            reply += "\n未删除：识别结果未达到自动删除门槛。"
        await command.reply_text(reply)
    except Exception as e:
        log.exception("manual ad check failed")
        await command.reply_text(f"手动识别失败：{e}")

async def cached_ai(text: str) -> Optional[AiResult]:
    h = text_hash(text)
    row = await store.one("SELECT result_json, expires_at FROM cache WHERE hash=?", (h,))
    if not row or row["expires_at"] < now_ts():
        return None
    try:
        d = json.loads(row["result_json"])
        return AiResult(**{k: d.get(k) for k in AiResult().__dict__.keys()})
    except Exception:
        return None

async def put_cache(text: str, res: AiResult):
    ttl = SPAM_CACHE_SECONDS if res.is_spam else NORMAL_CACHE_SECONDS
    await store.execute("INSERT OR REPLACE INTO cache(hash,result_json,expires_at) VALUES(?,?,?)", (text_hash(text), json.dumps(res.__dict__, ensure_ascii=False), now_ts()+ttl))

async def rate_limit_window(dq: deque, limit: int, seconds: int = 60) -> bool:
    t = now_ts()
    while dq and dq[0] < t - seconds: dq.popleft()
    if len(dq) >= limit: return False
    dq.append(t); return True

async def call_ai(message_text: str, group_context: str, user_context: str) -> AiResult:
    prompt = f'''你是 Telegram 群聊反垃圾审核系统。判断消息是否为垃圾、广告、诈骗、恶意链接、刷屏或骚扰。
只输出 JSON，不要 markdown，不要解释。字段：
{{"is_spam": true/false, "risk":"low/medium/high", "category":"normal/ad/scam/link_spam/flood/abuse/unknown", "confidence":0到1, "reason":"简短中文原因", "action":"allow/log/delete/mute/ban"}}
规则：普通聊天、技术讨论、正常链接不要误杀；明显广告/引流/机器人推广/campaign追踪码/日入兼职/色情资源推广必须标记为 spam；诈骗、色情、博彩、引流、可疑空投、私聊客服为 high。消息可能只含 Telegram 内联按钮或 t.me 群邀请链接；按钮文字如“加入群/进群/福利群/资源群/领取/点击”且链接导流时，应识别为广告。群链接本身不等于广告，结合按钮文字和上下文判断。
群信息：{group_context}
用户信息：{user_context}
消息：{message_text[:3500]}'''
    payload = {"model": AI_MODEL, "messages": [{"role": "user", "content": prompt}], "temperature": 0, "max_tokens": 300}
    headers = {"Authorization": f"Bearer {AI_API_KEY}", "Content-Type": "application/json"}
    async with httpx.AsyncClient(timeout=AI_TIMEOUT) as client:
        r = await client.post(f"{AI_BASE_URL}/chat/completions", headers=headers, json=payload)
        r.raise_for_status()
        content = r.json()["choices"][0]["message"]["content"].strip()
    m = re.search(r"\{.*\}", content, re.S)
    if not m:
        raise ValueError(f"AI 未返回 JSON: {content[:200]}")
    d = json.loads(m.group(0))
    return AiResult(bool(d.get("is_spam")), str(d.get("risk", "low")).lower(), str(d.get("category", "unknown")), float(d.get("confidence", 0)), str(d.get("reason", "")), str(d.get("action", "allow")).lower())

async def log_action(chat, user, text: str, ai: AiResult, action: str, ok: bool, error: str = ""):
    await store.execute("INSERT INTO logs(ts,chat_id,chat_title,user_id,username,text,ai_json,action,ok,error) VALUES(?,?,?,?,?,?,?,?,?,?)", (now_ts(), chat.id, chat.title or str(chat.id), user.id, user.username or "", text[:2000], json.dumps(ai.__dict__, ensure_ascii=False), action, 1 if ok else 0, error[:500]))

async def add_warning(chat_id: int, user_id: int) -> int:
    row = await store.one("SELECT count FROM warnings WHERE chat_id=? AND user_id=?", (chat_id, user_id))
    c = (row["count"] if row else 0) + 1
    await store.execute("INSERT INTO warnings(chat_id,user_id,count,updated_at) VALUES(?,?,?,?) ON CONFLICT(chat_id,user_id) DO UPDATE SET count=excluded.count, updated_at=excluded.updated_at", (chat_id, user_id, c, now_ts()))
    return c

async def handle_spam(update: Update, context: ContextTypes.DEFAULT_TYPE, ai: AiResult, text: str, mode: str):
    msg = update.effective_message; chat = update.effective_chat; user = update.effective_user
    action = "log"; ok = True; err = ""
    try:
        if ai.risk == "low" or ai.confidence < 0.60:
            action = "log"
        else:
            try:
                await msg.delete(); action = "delete"
            except TelegramError as e:
                ok = False; err = f"delete:{e}"
            warns = await add_warning(chat.id, user.id)
            high = ai.risk == "high" and ai.confidence >= 0.88
            if mode == "strict" and ai.risk == "medium" and ai.confidence >= 0.85:
                high = True
            if high or warns >= WARN_LIMIT_BAN:
                minutes = HIGH_RISK_BAN_MINUTES if warns < WARN_LIMIT_BAN else None
                try:
                    await do_ban(chat, user, 0, minutes, ai.reason, ai.risk, "ai", context, self_unban_allowed=(ai.risk != "high" and minutes is not None))
                    action = "ban"
                    await notify_owner(context, f"高风险封禁：{chat.title}\n用户：{display_user(user)} `{user.id}`\n风险：{ai.risk} {ai.confidence}\n原因：{ai.reason}\n消息：{text[:500]}")
                except TelegramError as e:
                    ok = False; err += f" ban:{e}"
            elif ai.risk == "medium" or warns >= WARN_LIMIT_MUTE:
                try:
                    await context.bot.restrict_chat_member(
                        chat.id,
                        user.id,
                        permissions=ChatPermissions(can_send_messages=False),
                        until_date=until_datetime(MEDIUM_RISK_MUTE_MINUTES),
                    )
                    action = "mute"
                except TelegramError as e:
                    err += f" mute:{e}"
            if mode != "silent" and action in {"delete", "mute", "ban"}:
                await send_spam_notice(chat, user.id, action, context)
    finally:
        await log_action(chat, user, text, ai, action, ok, err)


async def delete_notice_job(context: ContextTypes.DEFAULT_TYPE):
    data = context.job.data or {}
    try:
        await context.bot.delete_message(data["chat_id"], data["message_id"])
    except TelegramError as e:
        # It may already have been removed by an admin; this is not an operational error.
        log.info("notice auto-delete skipped chat=%s message=%s err=%s", data.get("chat_id"), data.get("message_id"), e)


async def send_spam_notice(chat, target_user_id: int, action: str, context: ContextTypes.DEFAULT_TYPE):
    """Send a safe short notice, then remove it automatically to keep the group clean."""
    keyboard = InlineKeyboardMarkup([
        [InlineKeyboardButton("封禁用户点击自助解除封禁", callback_data=f"self_unban:{chat.id}:{target_user_id}")],
        [InlineKeyboardButton("管理员点击解禁", callback_data=f"admin_unban:{chat.id}:{target_user_id}")],
    ])
    action_text = "已封禁" if action == "ban" else ("已禁言" if action == "mute" else "已删除")
    try:
        notice = await context.bot.send_message(chat.id, f"识别为广告，{action_text}。", reply_markup=keyboard)
        if NOTICE_DELETE_SECONDS > 0:
            context.job_queue.run_once(
                delete_notice_job,
                when=NOTICE_DELETE_SECONDS,
                data={"chat_id": chat.id, "message_id": notice.message_id},
                name=f"delete_notice:{chat.id}:{notice.message_id}",
            )
    except TelegramError:
        pass

async def callback_self_unban(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    if not q or not q.data:
        return
    await q.answer()
    parts = q.data.split(":")
    if len(parts) != 3:
        return
    kind, chat_id_s, user_id_s = parts
    chat_id = int(chat_id_s); target_id = int(user_id_s)
    clicker = q.from_user
    if kind == "self_unban":
        if clicker.id != target_id:
            await q.answer("这不是你的解封按钮。", show_alert=True)
            return
        row = await store.one("SELECT * FROM bans WHERE chat_id=? AND user_id=? AND status='active' ORDER BY started_at DESC LIMIT 1", (chat_id, target_id))
        if not row:
            await q.answer("没有找到活动封禁记录。", show_alert=True)
            return
        if not row["self_unban_allowed"] or not row["until_at"] or row["risk"] == "high":
            await q.answer("该封禁不支持自助解封，请联系管理员。", show_alert=True)
            return
        ts = now_ts()
        if row["last_appeal_at"] and ts - row["last_appeal_at"] < SELF_UNBAN_COOLDOWN_MINUTES * 60:
            await q.answer("申请太频繁，请稍后再试。", show_alert=True)
            return
        if row["appeal_count"] >= SELF_UNBAN_MAX_PER_DAY:
            await q.answer("今天自助解封次数已用完。", show_alert=True)
            return
        await store.execute("UPDATE bans SET appeal_count=appeal_count+1,last_appeal_at=? WHERE id=?", (ts, row["id"]))
        try:
            await context.bot.unban_chat_member(chat_id, target_id, only_if_banned=True)
            await store.execute("UPDATE bans SET status='self_unbanned' WHERE id=?", (row["id"],))
            await store.execute("INSERT OR REPLACE INTO observe(chat_id,user_id,until_at) VALUES(?,?,?)", (chat_id, target_id, ts + SELF_UNBAN_OBSERVE_HOURS * 3600))
            await q.edit_message_text("识别为广告。用户已自助解除封禁，进入观察期。")
            await notify_owner(context, f"用户点击按钮自助解封：`{target_id}` -> {row['chat_title']}")
        except TelegramError as e:
            await q.answer(f"解封失败：{e}", show_alert=True)
    elif kind == "admin_unban":
        if not await is_group_admin(chat_id, clicker.id, context):
            await q.answer("只有管理员可以点击解禁。", show_alert=True)
            return
        try:
            await context.bot.unban_chat_member(chat_id, target_id, only_if_banned=True)
            await context.bot.restrict_chat_member(chat_id, target_id, permissions=DEFAULT_USER_PERMISSIONS)
            await store.execute("UPDATE bans SET status='admin_unbanned' WHERE chat_id=? AND user_id=? AND status='active'", (chat_id, target_id))
            await q.edit_message_text("识别为广告。管理员已解禁该用户。")
        except TelegramError as e:
            await q.answer(f"解禁失败：{e}", show_alert=True)

async def handle_group_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    msg = update.effective_message; chat = update.effective_chat; user = update.effective_user
    if not msg or not chat: return
    if chat.type not in {ChatType.GROUP, ChatType.SUPERGROUP}: return
    # Messages sent as a channel or as the group/anonymous admin identity are trusted broadcasts.
    # Do not delete, mute, ban, or AI-check them; this protects the owner's own channel ads.
    if is_sender_chat_message(msg): return
    if not user or user.is_bot: return
    if not await ensure_authorized_or_leave(update, context): return
    row = await group_row(chat.id); mode = row["mode"] if row else DEFAULT_MODE
    if SKIP_ADMINS and await is_group_admin(chat.id, user.id, context): return
    wl = await store.one("SELECT 1 FROM whitelist WHERE chat_id=? AND user_id=?", (chat.id, user.id))
    if wl: return
    bio = await user_profile_bio(user.id, context)
    identity = f"用户名=@{user.username or ''}\n昵称={display_user(user)}\n个人简介={bio}".strip()
    profile_pre = await local_prefilter(identity)
    if profile_pre and profile_pre.is_spam:
        await handle_spam(update, context, profile_pre, f"[用户资料广告]\n{identity}\n[消息]\n{msg.text or msg.caption or ''}", mode)
        return
    if not await rate_limit_window(user_windows[(chat.id, user.id)], USER_MSG_PER_MINUTE):
        ai = AiResult(True, "medium", "flood", 0.9, "用户短时间发送过多消息", "mute")
        await handle_spam(update, context, ai, msg.text or msg.caption or "", mode); return
    text = message_content(msg)
    if not text: return
    text = await enrich_telegram_post_links(text)
    text = f"[用户资料]\n{identity}\n[消息]\n{text}"
    pre = await local_prefilter(text)
    if pre:
        if pre.is_spam: await handle_spam(update, context, pre, text, mode)
        return
    cached = await cached_ai(text)
    if cached:
        if cached.is_spam: await handle_spam(update, context, cached, text, mode)
        return
    if not await rate_limit_window(group_ai_windows[chat.id], GROUP_AI_PER_MINUTE) or not await rate_limit_window(global_ai_window, GLOBAL_AI_PER_MINUTE):
        await log_action(chat, user, text, AiResult(False, "low", "rate_limited", 0, "AI限流，跳过", "log"), "rate_limited", True)
        return
    try:
        observe = await store.one("SELECT until_at FROM observe WHERE chat_id=? AND user_id=? AND until_at>?", (chat.id, user.id, now_ts()))
        user_ctx = f"id={user.id}, username={user.username}, name={display_user(user)}, observe={bool(observe)}"
        ai = await call_ai(text, f"chat_id={chat.id}, title={chat.title}, mode={mode}", user_ctx)
        await put_cache(text, ai)
        if ai.is_spam:
            await handle_spam(update, context, ai, text, mode)
    except Exception as e:
        log.exception("AI check failed")
        await log_action(chat, user, text, AiResult(False, "low", "ai_error", 0, str(e), "log"), "ai_error", False, str(e))
        await notify_owner(context, f"AI 审核异常：{e}")

async def handle_private_appeal(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user; msg = update.effective_message
    if not SELF_UNBAN_ENABLED:
        await msg.reply_text("自助解封未开启。")
        return
    rows = await store.all("SELECT * FROM bans WHERE user_id=? AND status='active' ORDER BY started_at DESC LIMIT 5", (user.id,))
    if not rows:
        await msg.reply_text("你当前没有可处理的活动封禁记录。")
        return
    eligible = [r for r in rows if r["self_unban_allowed"] and r["until_at"] and r["risk"] != "high"]
    if not eligible:
        await msg.reply_text("你的封禁记录不支持自助解封，请联系群管理员。")
        return
    text = msg.text or ""
    if text.startswith("/start"):
        lines = ["你有可申请自助解封的记录。", "请回复一句话说明原因，并包含：我不是广告机器人，我会遵守群规", "不要发送链接、广告、联系方式。"]
        for r in eligible:
            until = datetime.fromtimestamp(r["until_at"]).strftime("%Y-%m-%d %H:%M")
            lines.append(f"- {r['chat_title']} 到 {until}，原因：{r['reason']}")
        await msg.reply_text("\n".join(lines)); return
    r = eligible[0]
    ts = now_ts()
    if r["last_appeal_at"] and ts - r["last_appeal_at"] < SELF_UNBAN_COOLDOWN_MINUTES*60:
        await msg.reply_text("申请太频繁，请稍后再试。")
        return
    if r["appeal_count"] >= SELF_UNBAN_MAX_PER_DAY:
        await msg.reply_text("今天自助申请次数已用完，请联系管理员。")
        return
    await store.execute("UPDATE bans SET appeal_count=appeal_count+1,last_appeal_at=? WHERE id=?", (ts, r["id"]))
    if "我不是广告机器人" not in text or "遵守群规" not in text or re.search(r"https?://|t\.me/|@\w+", text, re.I):
        await msg.reply_text("验证未通过：请按要求回复，不要带链接、@ 或广告内容。")
        return
    try:
        ai = await call_ai(text, "private appeal", f"user_id={user.id}")
        bad = ai.is_spam and ai.confidence >= 0.7
    except Exception:
        bad = False
    if bad:
        await msg.reply_text("AI 判断申诉内容风险较高，暂不自动解封。")
        return
    try:
        await context.bot.unban_chat_member(r["chat_id"], user.id, only_if_banned=True)
        await store.execute("UPDATE bans SET status='self_unbanned' WHERE id=?", (r["id"],))
        await store.execute("INSERT OR REPLACE INTO observe(chat_id,user_id,until_at) VALUES(?,?,?)", (r["chat_id"], user.id, ts + SELF_UNBAN_OBSERVE_HOURS*3600))
        await msg.reply_text(f"验证通过，已自动解封：{r['chat_title']}。接下来 {SELF_UNBAN_OBSERVE_HOURS} 小时为观察期，请勿发广告或可疑链接。")
        await notify_owner(context, f"用户自助解封：{display_user(user)} `{user.id}` -> {r['chat_title']}")
    except TelegramError as e:
        await msg.reply_text(f"解封失败：{e}")

async def periodic_unban(context: ContextTypes.DEFAULT_TYPE):
    rows = await store.all("SELECT * FROM bans WHERE status='active' AND until_at>0 AND until_at<=?", (now_ts(),))
    for r in rows:
        try:
            await context.bot.unban_chat_member(r["chat_id"], r["user_id"], only_if_banned=True)
            await store.execute("UPDATE bans SET status='expired_unbanned' WHERE id=?", (r["id"],))
            log.info("auto unbanned chat=%s user=%s", r["chat_id"], r["user_id"])
        except TelegramError as e:
            # A departed user can no longer be unbanned; mark it complete so the timer does not retry forever.
            if "Member not found" in str(e):
                await store.execute("UPDATE bans SET status='expired_not_found' WHERE id=?", (r["id"],))
                log.info("auto unban skipped departed member id=%s", r["id"])
            else:
                log.warning("auto unban failed id=%s err=%s", r["id"], e)

async def on_error(update: object, context: ContextTypes.DEFAULT_TYPE):
    log.exception("Update error: %s", context.error)

async def post_init(app: Application):
    me = await app.bot.get_me()
    log.info("Bot started: @%s id=%s", me.username, me.id)
    await notify_owner(app, f"AI 群反垃圾机器人已启动：@{me.username}")

def main():
    app = Application.builder().token(BOT_TOKEN).post_init(post_init).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("enable", cmd_enable))
    app.add_handler(CommandHandler("disable", cmd_disable))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("groups", cmd_groups))
    app.add_handler(CommandHandler("mode", cmd_mode))
    app.add_handler(CommandHandler("ban", cmd_ban))
    app.add_handler(CommandHandler("unban", cmd_unban))
    app.add_handler(CommandHandler(["checkad", "checkspam"], cmd_checkad))
    app.add_handler(CommandHandler(["whitelist", "whitelist_add", "whitelist_del"], cmd_whitelist))
    app.add_handler(CallbackQueryHandler(callback_self_unban, pattern=r"^(self_unban|admin_unban):"))
    app.add_handler(MessageHandler(filters.ChatType.PRIVATE & filters.TEXT, handle_private_appeal))
    app.add_handler(MessageHandler(filters.ChatType.GROUPS & (filters.TEXT | filters.CAPTION), handle_group_message))
    app.add_error_handler(on_error)
    app.job_queue.run_repeating(periodic_unban, interval=60, first=20)
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    main()

EOF_PY
  chmod +x "$APP_DIR/bot.py"
}

install_service() {
  apt-get update
  apt-get install -y python3 python3-venv python3-pip curl
  "$PYTHON_BIN" -m venv "$APP_DIR/venv"
  "$APP_DIR/venv/bin/pip" install --upgrade pip wheel
  "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"
  cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF_UNIT
[Unit]
Description=Telegram AI Spam Guard Bot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
EnvironmentFile=$CONFIG_FILE
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/bot.py
Restart=always
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_UNIT
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
}

status() {
  systemctl status "$SERVICE_NAME" --no-pager -l || true
  echo
  echo "最近日志："
  journalctl -u "$SERVICE_NAME" -n 80 --no-pager || true
}

uninstall() {
  systemctl disable --now "$SERVICE_NAME" || true
  rm -f "/etc/systemd/system/$SERVICE_NAME.service"
  systemctl daemon-reload
  echo "已停止并移除 systemd 服务。数据仍保留在 $APP_DIR"
}

need_root
case "$ACTION" in
  install)
    write_config
    write_app
    install_service
    status
    ;;
  configure)
    write_config
    systemctl restart "$SERVICE_NAME" || true
    status
    ;;
  update-code)
    write_app
    "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt" || true
    systemctl restart "$SERVICE_NAME" || true
    status
    ;;
  status)
    status
    ;;
  uninstall)
    uninstall
    ;;
  *)
    echo "用法：bash $0 install|configure|update-code|status|uninstall"
    exit 2
    ;;
esac
