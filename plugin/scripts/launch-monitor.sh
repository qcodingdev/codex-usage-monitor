#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="Codex Usage Monitor.app"

for APP in \
  "$HOME/Applications/$APP_NAME" \
  "/Applications/$APP_NAME" \
  "$ROOT/assets/$APP_NAME"
do
  if [[ -d "$APP" ]]; then
    open "$APP"
    exit 0
  fi
done

echo "找不到 $APP_NAME；请先安装桌面应用或重新安装插件。" >&2
exit 1
