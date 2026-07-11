# Telegram AI Spam Guard

Telegram 群 AI 反垃圾机器人安装脚本。支持授权群白名单、AI + 本地规则审核、广告处理、封禁/自助解封、审计日志及 systemd 运行。

## 安装

> 安装前先审阅脚本；配置中的 Bot Token 和 AI Key 只保存在服务器本地 `config.env`，不会提交到本仓库。

```bash
curl -fsSLO https://raw.githubusercontent.com/ggggghbbbbb/tg-ai-spam-guard/main/install_tg_ai_spam_bot.sh
chmod +x install_tg_ai_spam_bot.sh
sudo ./install_tg_ai_spam_bot.sh install
```

按提示输入 Telegram Bot Token、owner ID、AI API 地址、AI Key 和模型。运行中配置位于 `/opt/tg-ai-spam-bot/config.env`，权限为 `600`。

## 群内命令

- `/enable`：owner 在当前群授权并启用。
- `/status`：查看本群状态和机器人权限。
- `/mode normal|strict|silent`：管理员切换审核模式。
- 回复用户消息后：`/ban 60`、`/ban 1d`、`/ban forever`。
- 回复用户消息后：`/unban`。
- 回复可疑消息后：`/checkad` 手动识别文字、链接和**纯按钮广告**。
- 回复可疑消息后：`/checkad delete` 手动识别；确认是广告后立即删除原消息。
- `/checkspam` 是 `/checkad` 的别名。

## 广告识别范围

机器人会提取 Telegram 内联按钮的按钮文字和 URL 进行判断。带“加入群/进群/福利群/资源群/领取/点击”等导流文案的 `t.me` 群邀请链接将直接按广告处理；其余上下文不明确的群链接会交给 AI 判断，以减少误杀。

## 更新

在服务器上用新脚本更新代码（不覆盖 `config.env`、SQLite 数据和日志）：

```bash
sudo bash install_tg_ai_spam_bot.sh update-code
```
