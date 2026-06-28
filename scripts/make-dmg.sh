#!/usr/bin/env bash
#
# Builds a drag-and-drop installer DMG: MacHole.app next to an Applications
# shortcut, with a clean background. Builds the app first if needed.
#
# Usage:
#   scripts/make-dmg.sh [VERSION] [BUILD_NUMBER]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-1.0.0}"
BUILD="${2:-1}"

APP_NAME="MacHole"
VOL_NAME="MacHole"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG_FINAL="$DIST/$APP_NAME.dmg"
RW_DMG="$DIST/$APP_NAME-rw.dmg"
STAGING="$DIST/dmg-staging"
BG_SRC="$ROOT/Resources/dmg-background.png"

echo "==> Building app bundle"
"$ROOT/scripts/build-app.sh" "$VERSION" "$BUILD"

echo "==> Staging DMG contents"
rm -rf "$STAGING" "$DMG_FINAL" "$RW_DMG"
mkdir -p "$STAGING/.background"
cp -R "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
[ -f "$BG_SRC" ] && cp "$BG_SRC" "$STAGING/.background/background.png"

echo "==> Creating read-write image"
hdiutil create -srcfolder "$STAGING" -volname "$VOL_NAME" -fs HFS+ \
  -format UDRW -ov "$RW_DMG" >/dev/null

MOUNT_DIR="/Volumes/$VOL_NAME"
hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | grep '^/dev/' | head -1 | awk '{print $1}')
sleep 2

echo "==> Applying Finder layout (best-effort)"
# Run with a hard timeout so a Finder/automation hang can never block the build.
apply_layout() {
  osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set theOptions to the icon view options of container window
    set arrangement of theOptions to not arranged
    set icon size of theOptions to 96
    try
      set background picture of theOptions to file ".background:background.png"
    end try
    set position of item "$APP_NAME.app" of container window to {165, 185}
    set position of item "Applications" of container window to {495, 185}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
}
apply_layout >/dev/null 2>&1 &
OSA_PID=$!
( sleep 30; kill "$OSA_PID" >/dev/null 2>&1 ) >/dev/null 2>&1 &
WATCHDOG=$!
wait "$OSA_PID" 2>/dev/null || echo "    (layout step skipped — DMG is still a working installer)"
kill "$WATCHDOG" >/dev/null 2>&1 || true

sync
hdiutil detach "$DEVICE" >/dev/null 2>&1 || hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true

echo "==> Compressing final image"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_FINAL" >/dev/null
rm -f "$RW_DMG"
rm -rf "$STAGING"

echo ""
echo "Built: $DMG_FINAL  (version $VERSION)"