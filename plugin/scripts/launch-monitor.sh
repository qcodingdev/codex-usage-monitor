#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/assets/Codex Usage Monitor.app"

if [[ ! -d "$APP" ]]; then
  echo "找不到 $APP" >&2
  exit 1
fi

open "$APP"
