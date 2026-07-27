#!/usr/bin/env bash
# Packages FileFerry as a .zip alongside the .dmg.
#
# Corporate mail filters and chat tools frequently block .dmg attachments
# while allowing .zip, and a zip needs no mounting — useful when the recipient
# cannot reach GitHub at all.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/FileFerry.app"
VERSION="${1:-$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.1.0-dev)}"
STAGING="$ROOT/dist/zip-staging"
ZIP="$ROOT/dist/FileFerry-${VERSION}.zip"

[ -d "$APP" ] || { echo "error: $APP not found. Run Scripts/make-app.sh first." >&2; exit 1; }

rm -rf "$STAGING" "$ZIP"
mkdir -p "$STAGING"

# ditto, not zip: it preserves the bundle's symlinks and resource forks, and
# a plain `zip -r` can corrupt a signed .app.
ditto "$APP" "$STAGING/FileFerry.app"
cp "$ROOT/Scripts/install.sh" "$STAGING/install.sh"

cat > "$STAGING/Read Me.txt" <<'TXT'
FileFerry — copy files between a Mac and an Android phone over USB

INSTALL (one command, no Gatekeeper prompt)
  Unzip this, then in Terminal, cd into the unzipped folder and run:

    bash install.sh

  It copies the app to /Applications, clears the quarantine flag that would
  otherwise make macOS block it, and launches it. Nothing is downloaded —
  everything needed is in this archive.

OR BY HAND
  Drag FileFerry.app to /Applications, then run:

    xattr -dr com.apple.quarantine /Applications/FileFerry.app

  Skip that and macOS blocks the first launch; you would then have to allow
  it from System Settings > Privacy & Security > Open Anyway.

REQUIREMENTS
  - macOS 14 or later (Apple Silicon or Intel)
  - adb:  brew install --cask android-platform-tools
  - USB debugging on the phone:
      Settings > About phone > tap Build number seven times
      Settings > System > Developer options > USB debugging
  - A cable that carries data. A charge-only cable looks exactly like no
    phone being connected.
TXT

ditto -c -k --keepParent --sequesterRsrc "$STAGING" "$ZIP"
rm -rf "$STAGING"

echo "Built $ZIP ($(du -h "$ZIP" | cut -f1))"
shasum -a 256 "$ZIP"
