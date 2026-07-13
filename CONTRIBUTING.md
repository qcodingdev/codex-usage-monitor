# Contributing

感谢参与 Codex Usage Monitor。

## 开始开发

1. Fork 仓库并创建功能分支。
2. macOS 修改后运行 `apps/macos/build.sh`。
3. 修改插件脚本后运行 `node --check plugin/scripts/codex-usage-snapshot.mjs`。
4. 运行插件验证脚本，确认 `.codex-plugin/plugin.json` 和技能结构有效。
5. 提交 Pull Request，说明系统版本、Codex 版本和验证结果。

## 贡献边界

- 不要读取或提交认证文件、Token、Cookies 或完整 app-server 日志。
- 新增协议调用前，先确认它是只读并更新 `plugin/skills/usage-monitor/SKILL.md` 的安全边界。
- UI 改动请附截图或录屏，并说明是否影响最小化、退出和窗口刷新行为。
- 不要把项目描述成 OpenAI 官方插件。
