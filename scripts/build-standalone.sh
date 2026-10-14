#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
"$task_root/.venv/bin/python" "$task_root/scripts/build-standalone.py" "$@"
