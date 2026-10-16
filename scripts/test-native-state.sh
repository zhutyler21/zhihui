#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ROOT="$PROJECT_ROOT/work/native-regressions/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$RUN_ROOT"
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx14.0 \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework CoreMedia \
  "$PROJECT_ROOT/Sources/Models.swift" "$PROJECT_ROOT/Sources/RuntimePaths.swift" "$PROJECT_ROOT/Sources/API.swift" \
  "$PROJECT_ROOT/Sources/StateMachines.swift" "$PROJECT_ROOT/Sources/AudioImportSpool.swift" \
  "$PROJECT_ROOT/Sources/AppModel.swift" \
  "$PROJECT_ROOT/Sources/ProjectionState.swift" \
  "$PROJECT_ROOT/Sources/Recorder.swift" "$PROJECT_ROOT/Sources/NativeAudioTests.swift" \
  "$PROJECT_ROOT/tests/NativeStateTests.swift" -o "$RUN_ROOT/native-state-tests"
/usr/bin/python3 "$PROJECT_ROOT/tests/native-delay-server.py" --ready "$RUN_ROOT/ready.json" > "$RUN_ROOT/delay-server.log" 2>&1 &
TEST_SERVER_PID=$!
trap 'kill "$TEST_SERVER_PID" 2>/dev/null || true; wait "$TEST_SERVER_PID" 2>/dev/null || true' EXIT
for _ in {1..50}; do [ -f "$RUN_ROOT/ready.json" ] && break; sleep 0.1; done
TEST_PORT="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["port"])' "$RUN_ROOT/ready.json")"
shasum -a 256 "$PROJECT_ROOT"/Sources/*.swift > "$RUN_ROOT/source-sha256.txt"
shasum -a 256 "$RUN_ROOT/native-state-tests" > "$RUN_ROOT/executable-sha256.txt"
printf '%s\n' "$RUN_ROOT"
ZHIHUI_NATIVE_TEST_ROOT="$RUN_ROOT/spool" ZHIHUI_TEST_DIR="$RUN_ROOT/audio" \
  "$RUN_ROOT/native-state-tests" "$TEST_PORT" 2>&1 | tee "$RUN_ROOT/result.txt"
printf '%s\n' "$RUN_ROOT"
