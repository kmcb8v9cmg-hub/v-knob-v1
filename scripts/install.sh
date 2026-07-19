#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SOURCE_APP="$PROJECT_DIR/dist/Volume Knob.app"
INSTALL_APP="/Applications/Volume Knob.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  "$PROJECT_DIR/scripts/build-app.sh"
fi

ditto "$SOURCE_APP" "$INSTALL_APP"
xattr -cr "$INSTALL_APP"
codesign --force --deep --sign - "$INSTALL_APP"

echo "Installed: $INSTALL_APP"
echo "Open it from Applications, then optionally add it in System Settings > General > Login Items."

