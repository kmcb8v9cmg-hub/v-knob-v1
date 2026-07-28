#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_NAME="Volume Knob.app"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME"

cd "$PROJECT_DIR"
swift build -c release --disable-sandbox --cache-path /private/tmp/volume_knob_swiftpm_cache

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp ".build/release/VolumeKnob" "$APP_DIR/Contents/MacOS/VolumeKnob"
cp "Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "Built: $APP_DIR"
