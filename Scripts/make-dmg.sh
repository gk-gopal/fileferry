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

# Ship the installer inside the image so the whole thing is self-contained:
# mount, run one command, done. Running it as `bash install.sh` rather than
# double-clicking matters — a downloaded executable is quarantined, but a
# script read by an interpreter is not blocked.
cp "$ROOT/Scripts/install.sh" "$STAGING/install.sh"

# A README inside the image, because an unsigned build will be blocked by
# Gatekeeper and the right-click-Open workaround is not discoverable.
cat > "$STAGING/Read Me.txt" <<'TXT'
FileFerry — copy files between a Mac and an Android phone over USB

EASIEST: ONE COMMAND, NO GATEKEEPER PROMPT
  Open Terminal and paste this while this disk image is mounted:

    bash /Volumes/FileFerry/install.sh

  It copies the app to /Applications, clears the quarantine flag so macOS
  does not block it, checks for adb, and prints the SHA-256 it installed.

  Removing quarantine means macOS stops checking with Apple, so you are
  trusting whoever gave you this build. Compare the printed SHA-256 with
  SHA256SUMS.txt on the release page if you want to verify it.

OR DRAG IT ACROSS
  Drag FileFerry to the Applications folder. You will then have to allow it
  once, as described below.

FIRST LAUNCH
  This build is not notarized, so macOS blocks it the first time.

  macOS 15 (Sequoia) and later:
    1. Double-click FileFerry. macOS refuses and shows a warning.
    2. Open System Settings > Privacy & Security.
    3. Scroll down to "FileFerry was blocked" and click Open Anyway.
    4. Confirm, and enter your admin password.

  macOS 14 (Sonoma):
    Right-click FileFerry in Applications, choose Open, then confirm.

  Either way you only do this once.

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
