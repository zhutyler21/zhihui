#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ "$PROJECT_ROOT" = "/Users/zhutyler21/我的项目仓库/知会本地会议" ] || exit 1
OUTPUT_ROOT="$PROJECT_ROOT/work/fixture/onboarding-tests/quit-$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$OUTPUT_ROOT/module-cache" "$OUTPUT_ROOT/missing-project"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$OUTPUT_ROOT/module-cache" \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework CoreMedia \
  "$PROJECT_ROOT/Sources/MarkdownDocument.swift" "$PROJECT_ROOT/Sources/Models.swift" \
  "$PROJECT_ROOT/Sources/RuntimePaths.swift" "$PROJECT_ROOT/Sources/API.swift" "$PROJECT_ROOT/Sources/StateMachines.swift" \
  "$PROJECT_ROOT/Sources/AudioImportSpool.swift" "$PROJECT_ROOT/Sources/AppModel.swift" \
  "$PROJECT_ROOT/Sources/Recorder.swift" "$PROJECT_ROOT/Sources/NativeAudioTests.swift" \
  "$PROJECT_ROOT/tests/PreflightShutdownTests.swift" -o "$OUTPUT_ROOT/PreflightShutdownTests"
shasum -a 256 "$PROJECT_ROOT/Sources/AppModel.swift" "$PROJECT_ROOT/tests/PreflightShutdownTests.swift" \
  "$PROJECT_ROOT/scripts/test-preflight-shutdown.sh" "$OUTPUT_ROOT/PreflightShutdownTests" > "$OUTPUT_ROOT/sha256.txt"
ZHIHUI_DATA_DIR="$OUTPUT_ROOT/data" ZHIHUI_PROJECT_ROOT="$OUTPUT_ROOT/missing-project" \
  "$OUTPUT_ROOT/PreflightShutdownTests" 2>&1 | tee "$OUTPUT_ROOT/result.log"
printf '%s\n' "$OUTPUT_ROOT"
