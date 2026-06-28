#!/usr/bin/env bash
#
# Builds MacHole.app from the Swift package and ad-hoc code-signs it.
#
# Usage:
#   scripts/build-app.sh [VERSION] [BUILD_NUMBER]
#
# Examples:
#   scripts/build-app.sh                 # version 1.0.0, build 1
#   scripts/build-app.sh 1.2.0 42        # version 1.2.0, build 42
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-1.0.0}"
BUILD="${2:-1}"

APP_NAME="MacHole"
BUILD_DIR="$ROOT/.build/release"
APP_BUNDLE="$ROOT/dist/${APP_NAME}.app"
CONTENTS="$APP_BUNDLE/Contents"

echo "==> Compiling ${APP_NAME} (release)"
swift build -c release

echo "==> Assembling ${APP_NAME}.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BUILD_DIR/$APP_NAME" "$CONTENTS/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

# Stamp the requested version into the bundle's Info.plist.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$CONTENTS/Info.plist"

echo "==> Ad-hoc code-signing with entitlements"
codesign --force --deep \
  --sign - \
  --entitlements "$ROOT/Resources/MacHole.entitlements" \
  --options runtime \
  "$APP_BUNDLE"

echo "==> Verifying signature"
codesign --verify --verbose=2 "$APP_BUNDLE" || true

echo ""
echo "Built: $APP_BUNDLE  (version $VERSION, build $BUILD)"
echo "Run with: open \"$APP_BUNDLE\""
