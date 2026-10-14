#!/bin/zsh
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_data="$task_root/work/ui-qa"
mkdir -p "$task_data"
chmod 700 "$task_data"
/usr/bin/open -n --env "ZHIHUI_DATA_DIR=$task_data" --env "ZHIHUI_PORT=8788" "$task_root/dist/知会.app"
