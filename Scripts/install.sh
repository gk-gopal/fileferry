#!/usr/bin/env bash
# FileFerry installer.
#
#   Local DMG you already downloaded:
#     bash install.sh ~/Downloads/FileFerry-0.1.1.dmg
#
#   Straight from GitHub (needs the repo to be public):
#     curl -fsSL https://raw.githubusercontent.com/gk-gopal/fileferry/main/Scripts/install.sh | bash
#
# Installs to /Applications and removes the quarantine attribute, so macOS
# does not block the first launch. That is a deliberate trade: FileFerry is
# not notarized, so you are trusting this build instead of Apple's notary
# service. The script prints the SHA-256 it installed so you can compare it
# against the checksum published with the release.
set -euo pipefail

REPO="gk-gopal/fileferry"
APP="/Applications/FileFerry.app"
MOUNT="/tmp/fileferry-install-$$"
DMG="${1:-}"
DOWNLOADED=""

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  [ -d "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  [ -n "$DOWNLOADED" ] && rm -f "$DOWNLOADED" || true
}
trap cleanup EXIT

# --- checks -----------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "FileFerry is a macOS app."

MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || die "FileFerry needs macOS 14 or later (found $(sw_vers -productVersion))."

# --- get the disk image -----------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"

if [ -n "$DMG" ]; then
  [ -f "$DMG" ] || die "No such file: $DMG"
  info "Using $DMG"
elif [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/FileFerry.app" ]; then
  # Running from inside a mounted disk image: install what is right here
  # rather than going to the network. Works whether or not the repo is public.
  info "Installing from $SCRIPT_DIR"
  SOURCE_APP="$SCRIPT_DIR/FileFerry.app"
else
  info "Finding the latest release…"
  URL="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*\.dmg"' \
    | head -1 | cut -d'"' -f4)" \
    || die "Couldn't reach the GitHub API."

  [ -n "$URL" ] || die "No .dmg found in the latest release. If the repository is
still private, download the DMG from
  https://github.com/$REPO/releases
and re-run this script with its path:
  bash install.sh ~/Downloads/FileFerry-0.1.1.dmg"

  DOWNLOADED="/tmp/fileferry-$$.dmg"
  info "Downloading $(basename "$URL")…"
  curl -fL# "$URL" -o "$DOWNLOADED" || die "Download failed."
  DMG="$DOWNLOADED"
fi

# --- install ----------------------------------------------------------------

if [ -d "$APP" ]; then
  info "Replacing the existing FileFerry…"
  rm -rf "$APP"
fi

if [ -n "${SOURCE_APP:-}" ]; then
  CHECKSUM="(installed from a mounted image; check the DMG's own checksum)"
  cp -R "$SOURCE_APP" /Applications/
else
  CHECKSUM="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  mkdir -p "$MOUNT"
  hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MOUNT" \
    || die "Couldn't mount the disk image."
  [ -d "$MOUNT/FileFerry.app" ] || die "That disk image doesn't contain FileFerry.app."
  cp -R "$MOUNT/FileFerry.app" /Applications/
  hdiutil detach "$MOUNT" -quiet
fi

# The step that matters: without this, macOS blocks the first launch and the
# user has to allow it from System Settings > Privacy & Security.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

codesign --verify --strict "$APP" 2>/dev/null \
  || warn "The signature didn't verify. Apple Silicon needs a valid signature to run arm64 code."

# --- adb --------------------------------------------------------------------

if ! command -v adb >/dev/null 2>&1 \
   && [ ! -x /opt/homebrew/bin/adb ] && [ ! -x /usr/local/bin/adb ]; then
  warn "adb isn't installed. FileFerry needs it to talk to your phone:"
  printf '\n    brew install --cask android-platform-tools\n\n'
fi

# --- done -------------------------------------------------------------------

cat <<EOF

$(info "Installed $APP")

  SHA-256 of the image installed:
    $CHECKSUM
  Compare it with SHA256SUMS.txt on the release page if you want to verify it.

Next, on the phone (once):
  1. Settings > About phone > tap "Build number" seven times
  2. Settings > System > Developer options > turn on "USB debugging"
  3. Plug it into this Mac and tap "Allow", ticking "Always allow"

A cable that only charges will look exactly like no phone at all.

EOF

open "$APP"
