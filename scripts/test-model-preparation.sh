#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ "$PROJECT_ROOT" = "/Users/zhutyler21/我的项目仓库/知会本地会议" ] || { printf '%s\n' 'Unexpected project root'; exit 1; }
OUTPUT_ROOT="$PROJECT_ROOT/work/setup-and-trash-v2/native-tests/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$OUTPUT_ROOT/module-cache"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$OUTPUT_ROOT/module-cache" \
  "$PROJECT_ROOT/Sources/ModelPreparation.swift" "$PROJECT_ROOT/tests/ModelPreparationTests.swift" -o "$OUTPUT_ROOT/ModelPreparationTests"
ZHIHUI_MODEL_TEST_ROOT="$OUTPUT_ROOT/fixture" "$OUTPUT_ROOT/ModelPreparationTests" > "$OUTPUT_ROOT/result.log" 2>&1
cat "$OUTPUT_ROOT/result.log"
shasum -a 256 "$PROJECT_ROOT/Sources/ModelPreparation.swift" "$PROJECT_ROOT/tests/ModelPreparationTests.swift" \
  "$PROJECT_ROOT/scripts/test-model-preparation.sh" "$OUTPUT_ROOT/ModelPreparationTests" > "$OUTPUT_ROOT/sha256.txt"
printf '%s\n' "$OUTPUT_ROOT"
