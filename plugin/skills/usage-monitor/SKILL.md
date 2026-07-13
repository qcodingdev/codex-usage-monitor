---
name: usage-monitor
description: Read the current Codex plan balance, 5-hour and 7-day rate-limit windows, reset times, Credits balance, and account Token activity; or launch the bundled macOS floating monitor. Use when the user asks about Codex usage, quota, balance, limits, credits, tokens, or the usage dashboard.
---

# Codex Usage Monitor

Use the bundled scripts instead of scraping the Codex UI or reading authentication files.

## Read a snapshot

Run:

```bash
node <plugin-root>/scripts/codex-usage-snapshot.mjs
```

Report the 5-hour and 7-day remaining percentages, reset times, plan, Credits balance, today's Token activity, lifetime Token activity, and last refresh time. Preserve the distinction between plan-window usage and Credits.

For machine-readable output, run:

```bash
node <plugin-root>/scripts/codex-usage-snapshot.mjs --json
```

## Launch the floating monitor

On macOS, when the user asks to launch, pin, float, or continuously monitor usage, run:

```bash
zsh <plugin-root>/scripts/launch-monitor.sh
```

Launching a GUI application may require user approval. The monitor refreshes every 60 seconds and can be dragged. Clicking its menu-bar item toggles the panel.

## Security boundary

- Only call the read-only Codex app-server methods `account/rateLimits/read` and `account/usage/read`.
- Never read, print, copy, or persist ChatGPT authentication tokens.
- Do not call reset-credit consumption, login, logout, or account mutation methods.
- The monitor checks the installed Codex CLI, the Codex paths in the shell environment, and the `codex` binary bundled inside `ChatGPT.app`. A separate CLI installation is not required when the desktop app is present.
- Only if both the CLI and the desktop app's bundled app-server are unavailable should you report an error; do not fall back to private web endpoints or UI scraping.
