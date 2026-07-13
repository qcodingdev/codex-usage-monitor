# Codex Usage Monitor plugin

这是 Codex Usage Monitor 的插件部分。它提供一次性查询技能，并在 macOS 上附带菜单栏与悬浮面板启动器。

数据来自本机 Codex `app-server` 的 `account/rateLimits/read` 和 `account/usage/read`，不会读取、复制或保存登录凭据。监控器只发送只读请求，不运行模型任务，也不会额外消耗 Token。

## 安装

将本目录作为本地插件安装，或使用项目 Release 中的插件 ZIP。安装后可询问：

> 查看我的 Codex 套餐余额、5 小时和 7 天窗口，以及 Token 活动。

## macOS 浮窗

```bash
zsh scripts/launch-monitor.sh
```

浮窗每 60 秒刷新。点击“最小化”只隐藏面板并保留菜单栏图标；点击“退出”才会停止监控进程。程序会优先检查 CLI，并回退到 ChatGPT.app 内置的 `codex`，因此只有桌面版也可以运行。

Windows 伴侣程序尚未包含在 v0.1.0，见仓库中的 `apps/windows/README.md`。
