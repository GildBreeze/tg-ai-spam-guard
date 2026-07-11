# Telegram Spam Guard

用于 Telegram 群组的广告与垃圾消息管理机器人。支持本地规则、模型判断、群授权、封禁记录、临时解封和日志审计。

## 功能

- 仅在授权群工作，避免被随意拉群使用。
- 识别文字广告、链接广告、`t.me` 群引流、按钮广告和常见刷屏内容。
- 按风险等级执行删除、禁言或封禁。
- 广告处理提示默认显示 2 分钟后自动删除，保持群聊整洁。
- 支持管理员手动检查可疑消息。
- 支持白名单、群模式、临时封禁、到期自动解封和自助申诉。
- 使用 SQLite 保存群配置、处理记录和缓存。
- 以 systemd 服务方式运行，断线或异常退出后自动拉起。

## 环境

- Linux 服务器（建议 Debian / Ubuntu）
- Python 3.9 或更高版本
- 一个已创建的 Telegram Bot
- 一个兼容 OpenAI Chat Completions 的接口

机器人需要在目标群内设为管理员，并至少授予：

- 删除消息
- 限制成员
- 封禁成员

如需完整监听普通群消息，请在 BotFather 中关闭该机器人的 Group Privacy，或确认管理员权限和群消息接收设置正确。

## 部署

下载脚本并执行安装：

```bash
curl -fsSLO https://raw.githubusercontent.com/ggggghbbbbb/tg-ai-spam-guard/main/install_tg_ai_spam_bot.sh
chmod +x install_tg_ai_spam_bot.sh
sudo ./install_tg_ai_spam_bot.sh install
```

安装过程会要求填写：

- `BOT_TOKEN`：Telegram Bot Token
- `OWNER_IDS`：机器人所有者的 Telegram 数字 ID，可填写多个，用逗号分隔
- `AI_BASE_URL`：模型接口地址，例如 `https://example.com/v1`
- `AI_API_KEY`：模型接口密钥
- `AI_MODEL`：模型名称
- `UNAUTHORIZED_POLICY`：未授权群策略，`leave` 为自动退出，`silent` 为静默不处理
- `DEFAULT_MODE`：默认审核模式

安装完成后服务名为：

```bash
systemctl status tg-ai-spam-bot
```

配置文件位于：

```text
/opt/tg-ai-spam-bot/config.env
```

该文件仅保存在服务器本地，权限会设置为 `600`。不要将它提交到 Git 仓库。

## 群内使用

先把机器人加入群并设为管理员，再由 owner 在群内发送：

```text
/enable
```

常用命令：

```text
/status
/mode normal
/mode strict
/mode silent
```

回复某位成员的消息后可执行：

```text
/ban 60
/ban 1h
/ban 1d
/ban forever
/unban
```

白名单命令：

```text
/whitelist
/whitelist_add
/whitelist_del
```

## 手动检查广告

回复一条可疑消息，再发送：

```text
/checkad
```

机器人会返回分类、风险等级、置信度和判断原因。该命令可检查正文、链接、内联按钮和纯按钮消息。

确认删除时使用：

```text
/checkad delete
```

`/checkspam` 与 `/checkad` 相同。

## 配置说明

常用配置项：

```ini
# 广告处理提示显示时长，单位秒；设为 0 则不自动删除
NOTICE_DELETE_SECONDS=120

# 普通模式 / 严格模式 / 静默模式
DEFAULT_MODE=normal

# 每群、每用户、全局的模型调用保护
GROUP_AI_PER_MINUTE=30
USER_MSG_PER_MINUTE=10
GLOBAL_AI_PER_MINUTE=100

# 处罚策略
HIGH_RISK_BAN_MINUTES=1440
MEDIUM_RISK_MUTE_MINUTES=60
WARN_LIMIT_MUTE=2
WARN_LIMIT_BAN=4
```

修改配置后重启服务：

```bash
sudo systemctl restart tg-ai-spam-bot
```

## 更新

重新下载最新版脚本后，在服务器执行：

```bash
sudo bash install_tg_ai_spam_bot.sh update-code
```

`update-code` 只更新程序代码和依赖，不会覆盖本地的 `config.env`、数据库和日志。

## 常用维护命令

```bash
# 查看运行状态
sudo systemctl status tg-ai-spam-bot

# 查看实时日志
sudo journalctl -u tg-ai-spam-bot -f

# 查看最近日志
sudo journalctl -u tg-ai-spam-bot -n 100 --no-pager

# 重启服务
sudo systemctl restart tg-ai-spam-bot

# 停止服务
sudo systemctl stop tg-ai-spam-bot
```

运行数据默认保存在：

```text
/opt/tg-ai-spam-bot/data/
/opt/tg-ai-spam-bot/logs/
```
