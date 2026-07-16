#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP_NAME="Codex Usage Monitor.app"
TARGET_DIR="$HOME/Applications"
TARGET_APP="$TARGET_DIR/$APP_NAME"
BIN_DIR="$HOME/.local/bin"
CLI_TARGET="$BIN_DIR/codex-usage-monitor"

resolve_source_app() {
  local candidate
  for candidate in \
    "$ROOT/$APP_NAME" \
    "$ROOT/build/$APP_NAME" \
    "$ROOT/../../plugin/assets/$APP_NAME"
  do
    if [[ -d "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

if ! SOURCE_APP="$(resolve_source_app)"; then
  echo "找不到 $APP_NAME，请确认安装程序与应用位于同一目录。" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR" "$BIN_DIR"
ditto "$SOURCE_APP" "$TARGET_APP"
cp "$ROOT/codex-usage-monitor" "$CLI_TARGET"
chmod +x "$CLI_TARGET"

echo "已安装应用：$TARGET_APP"
echo "已安装命令：$CLI_TARGET"
if [[ ":${PATH}:" != *":$BIN_DIR:"* ]]; then
  echo "提示：请将 $BIN_DIR 加入 PATH，之后可运行 codex-usage-monitor。"
fi

if [[ "${CODEX_USAGE_MONITOR_SKIP_OPEN:-0}" != "1" ]]; then
  open "$TARGET_APP"
fi
