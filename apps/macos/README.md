# Codex Usage Monitor

macOS 菜单栏和悬浮面板，用 Codex `app-server` 的只读协议显示：

- 5 小时与 7 天用量窗口、剩余比例和重置时间
- ChatGPT 套餐类型和 Credits 余额
- 今日、累计 Token 与连续活跃天数
- 桌面版和 CLI 共用账户的汇总活动

应用不会读取、复制或保存 ChatGPT 登录凭据。它启动本机 `codex app-server`，调用
`account/rateLimits/read` 与 `account/usage/read`，每 60 秒刷新一次。

## 性能

监控器不运行模型任务，只保持一个本地 app-server 进程并每分钟发送两次只读请求。当前机器的空闲实测约为：悬浮应用 30 MB 内存、app-server 80 MB 内存、CPU 接近 0%；实际数值会随 Codex 版本变化。不会额外消耗模型 Token 或套餐额度。点击“最小化”只隐藏面板，菜单栏仍保留并继续刷新；点击“退出”才会停止监控进程。

## 构建

```bash
chmod +x build.sh
./build.sh
```

应用会优先尝试本地 CLI，并自动回退到 ChatGPT.app 内置的 `codex`。因此只安装桌面版也可以运行。

构建产物中的 ZIP 包含双击安装程序。安装后可从 Spotlight 搜索 `Codex Usage Monitor`，也可以运行：

```bash
codex-usage-monitor
```

如果你的桌面版安装在非标准位置，可以从终端运行：

```bash
CODEX_BIN="$(command -v codex)" open "build/Codex Usage Monitor.app"
```
