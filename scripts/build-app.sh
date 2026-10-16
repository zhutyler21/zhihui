#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${ZHIHUI_APP_OUTPUT:-$PROJECT_ROOT/dist/知会.app}"
BUILD_ROOT="$PROJECT_ROOT/work/native-build"
SIGNING_IDENTITY="${ZHIHUI_SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ] && [ -f "$PROJECT_ROOT/work/local-signing-identity" ]; then
  IFS= read -r SIGNING_IDENTITY < "$PROJECT_ROOT/work/local-signing-identity"
fi
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$BUILD_ROOT"
SPARKLE_PATH="$(python3 "$PROJECT_ROOT/scripts/setup-sparkle.py")"
xcrun -sdk macosx metal -mmacosx-version-min=14.0 -c "$PROJECT_ROOT/Resources/WelcomeGlass.metal" \
  -o "$BUILD_ROOT/WelcomeGlass.air"
xcrun -sdk macosx metallib "$BUILD_ROOT/WelcomeGlass.air" \
  -o "$APP_PATH/Contents/Resources/default.metallib"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  -module-name Zhihui -module-cache-path "$BUILD_ROOT/module-cache" \
  -framework SwiftUI -framework AppKit -framework AVFoundation \
  -framework ScreenCaptureKit -framework CoreMedia \
  -F "$SPARKLE_PATH" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$PROJECT_ROOT"/Sources/*.swift -o "$BUILD_ROOT/知会"
cp "$BUILD_ROOT/知会" "$APP_PATH/Contents/MacOS/知会"
xcrun swift "$PROJECT_ROOT/scripts/AppIcon.swift" "$BUILD_ROOT/AppIcon.iconset"
/usr/bin/iconutil --convert icns "$BUILD_ROOT/AppIcon.iconset" --output "$APP_PATH/Contents/Resources/AppIcon.icns"
cp "$PROJECT_ROOT/Resources/ModelCatalog.json" "$APP_PATH/Contents/Resources/ModelCatalog.json"
/usr/bin/python3 - "$PROJECT_ROOT" "$APP_PATH" <<'PY'
import base64, json, pathlib, plistlib, sys
root, app = sys.argv[1:]
info = {
    'CFBundleName': '知会', 'CFBundleDisplayName': '知会',
    'CFBundleIdentifier': 'io.local.zhihui.meetings', 'CFBundleExecutable': '知会',
    'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.8.0',
    'CFBundleVersion': '21', 'LSMinimumSystemVersion': '14.0',
    'CFBundleIconFile': 'AppIcon',
    'CFBundleDevelopmentRegion': 'zh-Hans', 'CFBundleLocalizations': ['zh-Hans'],
    'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication',
    'NSMicrophoneUsageDescription': '知会需要麦克风权限，将你选择的会议录音在本机转写为中文。录音不会发送到外部AI服务。',
    'NSScreenCaptureUsageDescription': '知会使用系统音频录制权限，记录这台Mac播放的会议声音。不会保存屏幕画面。',
    'NSAudioCaptureUsageDescription': '知会需要系统音频录制权限，在本机转写线上会议的声音。',
    'ZhihuiProjectRoot': root,
    'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
}
updates = json.loads((pathlib.Path(root)/'Resources/Updates.json').read_text())
if len(base64.b64decode(updates['public_key'], validate=True)) != 32:
    raise SystemExit('Configure the Sparkle public key before building.')
info.update({'SUFeedURL': updates['feed_url'], 'SUPublicEDKey': updates['public_key'],
             'SUEnableAutomaticChecks': True, 'SUScheduledCheckInterval': 86400,
             'SUAllowsAutomaticUpdates': False, 'SUAutomaticallyUpdate': False,
             'SUSendProfileInfo': False, 'SUVerifyUpdateBeforeExtraction': True,
             'SURequireSignedFeed': True})
with open(pathlib.Path(app)/'Contents/Info.plist', 'wb') as f: plistlib.dump(info, f)
with open(pathlib.Path(root)/'work/native-build/entitlements.plist', 'wb') as f:
    plistlib.dump({'com.apple.security.device.audio-input': True}, f)
PY
python3 "$PROJECT_ROOT/scripts/setup-sparkle.py" --distribution "$SPARKLE_PATH" --embed "$APP_PATH" --sign "$SIGNING_IDENTITY"
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --entitlements "$BUILD_ROOT/entitlements.plist" "$APP_PATH"
/usr/bin/codesign --verify --strict "$APP_PATH"
printf '%s\n' "$APP_PATH"
