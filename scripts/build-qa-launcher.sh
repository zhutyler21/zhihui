#!/bin/zsh
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_app="$task_root/work/知会验收启动器.app"
mkdir -p "$task_app/Contents/MacOS"
xcrun swiftc -parse-as-library -O -framework AppKit "$task_root/scripts/qa-launcher.swift" -o "$task_app/Contents/MacOS/qa-launcher"
python3 - "$task_root" "$task_app" <<'PY'
from pathlib import Path
import sys,plistlib
root,app=map(Path,sys.argv[1:])
with (app/'Contents/Info.plist').open('wb') as f:
 plistlib.dump({'CFBundleIdentifier':'io.local.zhihui.qa-launcher','CFBundleExecutable':'qa-launcher','CFBundleName':'知会验收启动器','CFBundlePackageType':'APPL','CFBundleVersion':'1','ZhihuiProjectRoot':str(root)},f)
PY
codesign --force --sign - "$task_app"
