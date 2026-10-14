#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ "$PROJECT_ROOT" = "/Users/zhutyler21/我的项目仓库/知会本地会议" ] || { printf '%s\n' 'Unexpected project root'; exit 1; }
OUTPUT_ROOT="$PROJECT_ROOT/work/fixture/onboarding-tests/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$OUTPUT_ROOT/module-cache"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 -module-cache-path "$OUTPUT_ROOT/module-cache" \
  "$PROJECT_ROOT/Sources/OnboardingState.swift" "$PROJECT_ROOT/tests/OnboardingTests.swift" \
  -o "$OUTPUT_ROOT/OnboardingTests"
ZHIHUI_ONBOARDING_TEST_ROOT="$OUTPUT_ROOT/store" "$OUTPUT_ROOT/OnboardingTests" 2>&1 | tee "$OUTPUT_ROOT/result.log"
shasum -a 256 "$PROJECT_ROOT/Sources/OnboardingState.swift" "$PROJECT_ROOT/tests/OnboardingTests.swift" \
  "$PROJECT_ROOT/scripts/test-onboarding.sh" "$OUTPUT_ROOT/OnboardingTests" > "$OUTPUT_ROOT/sha256.txt"
printf '%s\n' "$OUTPUT_ROOT"
