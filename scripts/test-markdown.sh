#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/work/fixture/markdown-tests/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$BUILD_ROOT/module-cache"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 \
  -module-cache-path "$BUILD_ROOT/module-cache" \
  "$PROJECT_ROOT/Sources/MarkdownDocument.swift" "$PROJECT_ROOT/tests/MarkdownTests.swift" \
  -o "$BUILD_ROOT/MarkdownTests"
"$BUILD_ROOT/MarkdownTests"
xcrun swiftc -swift-version 5 -D MARKDOWN_APP_MODEL_TESTS -target arm64-apple-macosx14.0 \
  -module-cache-path "$BUILD_ROOT/module-cache" \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework CoreMedia \
  "$PROJECT_ROOT/Sources/MarkdownDocument.swift" "$PROJECT_ROOT/Sources/Models.swift" \
  "$PROJECT_ROOT/Sources/API.swift" "$PROJECT_ROOT/Sources/StateMachines.swift" \
  "$PROJECT_ROOT/Sources/AudioImportSpool.swift" "$PROJECT_ROOT/Sources/AppModel.swift" \
  "$PROJECT_ROOT/Sources/Recorder.swift" "$PROJECT_ROOT/Sources/NativeAudioTests.swift" \
  "$PROJECT_ROOT/tests/MarkdownTests.swift" -o "$BUILD_ROOT/MarkdownAppModelTests"
/usr/bin/python3 "$PROJECT_ROOT/tests/native-delay-server.py" --ready "$BUILD_ROOT/ready.json" > "$BUILD_ROOT/server.log" 2>&1 &
TEST_SERVER_PID=$!
trap 'kill "$TEST_SERVER_PID" 2>/dev/null || true; wait "$TEST_SERVER_PID" 2>/dev/null || true' EXIT
for _ in {1..50}; do [ -f "$BUILD_ROOT/ready.json" ] && break; sleep 0.1; done
TEST_PORT="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$BUILD_ROOT/ready.json")"
ZHIHUI_NATIVE_TEST_ROOT="$BUILD_ROOT/spool" ZHIHUI_TEST_DIR="$BUILD_ROOT/audio" \
  "$BUILD_ROOT/MarkdownAppModelTests" "$TEST_PORT" 2>&1 | tee "$BUILD_ROOT/result.log"
shasum -a 256 "$PROJECT_ROOT/Sources/MarkdownDocument.swift" "$PROJECT_ROOT/Sources/MarkdownNotesView.swift" \
  "$PROJECT_ROOT/Sources/MarkdownRendering.swift" "$PROJECT_ROOT/Sources/Models.swift" \
  "$PROJECT_ROOT/Sources/API.swift" "$PROJECT_ROOT/Sources/StateMachines.swift" \
  "$PROJECT_ROOT/Sources/AudioImportSpool.swift" "$PROJECT_ROOT/Sources/AppModel.swift" \
  "$PROJECT_ROOT/Sources/Recorder.swift" "$PROJECT_ROOT/Sources/NativeAudioTests.swift" \
  "$PROJECT_ROOT/tests/MarkdownTests.swift" "$PROJECT_ROOT/tests/native-delay-server.py" \
  "$PROJECT_ROOT/scripts/test-markdown.sh" > "$BUILD_ROOT/source-sha256.txt"
shasum -a 256 "$BUILD_ROOT/MarkdownTests" "$BUILD_ROOT/MarkdownAppModelTests" > "$BUILD_ROOT/executable-sha256.txt"
printf '%s\n' "$BUILD_ROOT"
