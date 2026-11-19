#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
STAGE="$(mktemp -d "$BUILD_DIR.tmp.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

if [[ -e "$BUILD_DIR/BarFold.app" ]]; then
    echo "Move the previous build/BarFold.app elsewhere before replacing it." >&2
    exit 1
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

xcodebuild -project "$ROOT/Thaw.xcodeproj" -scheme Thaw -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR/DerivedData" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_DEBUG_DYLIB=NO build

APP="$STAGE/BarFold.app"
ditto "$BUILD_DIR/DerivedData/Build/Products/Release/Thaw.app" "$APP"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if ! codesign --verify --deep --strict "$SPARKLE"; then
    codesign --force --deep --sign - "$SPARKLE"
fi
for SERVICE in MenuBarCaptureService MenuBarItemService; do
    codesign --force --sign - "$APP/Contents/XPCServices/$SERVICE.xpc"
done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
mv "$APP" "$BUILD_DIR/BarFold.app"
printf 'Built %s\n' "$BUILD_DIR/BarFold.app"
