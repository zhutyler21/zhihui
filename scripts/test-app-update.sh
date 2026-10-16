#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$task_root/work/update-tests/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$test_root"
sparkle_root="$(python3 "$task_root/scripts/setup-sparkle.py")"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
  -framework SwiftUI -framework AppKit -F "$sparkle_root" -framework Sparkle \
  -Xlinker -rpath -Xlinker "$sparkle_root" \
  "$task_root/Sources/Design.swift" "$task_root/Sources/AppUpdater.swift" \
  "$task_root/tests/AppUpdaterTests.swift" -o "$test_root/update-tests"
"$test_root/update-tests" | tee "$test_root/result.log"
shasum -a 256 "$task_root/Sources/AppUpdater.swift" "$task_root/tests/AppUpdaterTests.swift" \
  "$task_root/scripts/test-app-update.sh" "$test_root/update-tests" > "$test_root/sha256.txt"
