#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/work/standalone-release-v0.5.0/native-host-build"
mkdir -p "$RUN"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/RuntimePaths.swift" "$ROOT/Sources/API.swift" \
  "$ROOT/tests/PackagedBackendHostTests.swift" -o "$RUN/packaged-host-test"
echo "$RUN/packaged-host-test"
