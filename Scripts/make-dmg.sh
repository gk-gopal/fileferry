#!/usr/bin/env bash
# Packages dist/FileFerry.app into a distributable disk image.
#
# Uses hdiutil rather than create-dmg so there is no Homebrew dependency to
# install before a release can be cut.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/FileFerry.app"
VERSION="${1:-$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.1.0-dev)}"
STAGING="$ROOT/dist/dmg-staging"
DMG="$ROOT/dist/FileFerry-${VERSION}.dmg"

if [ ! -d "$APP" ]; then
  echo "error: $APP not found. Run Scripts/make-app.sh first." >&2
  exit 1
fi

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# A README inside the image, because an unsigned build will be blocked by
# Gatekeeper and the right-click-Open workaround is not discoverable.
cat > "$STAGING/Read Me.txt" <<'TXT'
FileFerry — copy files between a Mac and an Android phone over USB

INSTALLING
  Drag FileFerry to the Applications folder.

FIRST LAUNCH
  This build is not notarized yet, so macOS will refuse to open it on a
  double-click. Right-click FileFerry in Applications, choose Open, then
  confirm. You only have to do this once.

REQUIREMENTS
  - macOS 14 or later
  - adb:  brew install --cask android-platform-tools
  - USB debugging enabled on the phone:
      Settings > About phone > tap Build number seven times
      Settings > System > Developer options > USB debugging
TXT

hdiutil create \
  -volname "FileFerry" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG"

rm -rf "$STAGING"
echo "Built $DMG"
