#!/usr/bin/env bash
# Assembles FileFerry.app around the SPM-built executable.
#
# SwiftPM cannot produce a macOS .app bundle, and hand-maintaining an
# .xcodeproj means a merge-conflict magnet in a repo that otherwise builds
# with `swift build`. This script bridges the gap: one binary, one Info.plist.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/FileFerry.app"
VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo "0.1.0-dev")"

# Command Line Tools does not ship Swift Testing, and its SDK differs from
# Xcode's. Prefer Xcode when it is present.
if [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Build for both architectures by default. A native-only build runs fine on
# the machine that made it and fails outright on the other kind of Mac, which
# is exactly the bug you do not want to discover by handing someone a DMG.
# Set UNIVERSAL=0 for a faster native-only build while developing.
UNIVERSAL="${UNIVERSAL:-1}"

if [ "$UNIVERSAL" = "1" ]; then
  echo "Building FileFerry ($CONFIGURATION, universal arm64 + x86_64)…"
  swift build -c "$CONFIGURATION" --product FileFerry --arch arm64 --arch x86_64
  # --arch redirects output; --show-bin-path reports the native path instead.
  CONFIG_DIR="$(echo "$CONFIGURATION" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
  BINARY="$ROOT/.build/apple/Products/$CONFIG_DIR/FileFerry"
else
  echo "Building FileFerry ($CONFIGURATION, native only)…"
  swift build -c "$CONFIGURATION" --product FileFerry
  BINARY="$(swift build -c "$CONFIGURATION" --product FileFerry --show-bin-path)/FileFerry"
fi

if [ ! -f "$BINARY" ]; then
  echo "error: built binary not found at $BINARY" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/FileFerry"

# The icon is drawn in code (Scripts/make-icon.swift) rather than checked in
# as binary PNGs, so it stays reviewable in a diff.
echo "Rendering icon…"
rm -rf "$ROOT/dist/FileFerry.iconset"
swift "$ROOT/Scripts/make-icon.swift" "$ROOT/dist/FileFerry.iconset" >/dev/null
iconutil -c icns "$ROOT/dist/FileFerry.iconset" -o "$APP/Contents/Resources/FileFerry.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FileFerry</string>
    <key>CFBundleDisplayName</key><string>FileFerry</string>
    <key>CFBundleIdentifier</key><string>app.fileferry.FileFerry</string>
    <key>CFBundleExecutable</key><string>FileFerry</string>
    <key>CFBundleIconFile</key><string>FileFerry</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>

    <!-- macOS gates these folders behind a consent prompt. Without a usage
         description the prompt is bare, which is a poor thing to show a user
         who is already being asked to trust an unnotarized app. -->
    <key>NSDocumentsFolderUsageDescription</key>
    <string>FileFerry needs access to Documents so you can copy files there from your phone, and send files from it.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>FileFerry needs access to the Desktop so you can copy files there from your phone, and send files from it.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>FileFerry needs access to Downloads so you can copy files there from your phone, and send files from it.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>FileFerry needs access to external drives and memory cards so you can copy files between them and your phone directly.</string>
    <key>NSHumanReadableCopyright</key><string>MIT licensed</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. A Developer ID signature and notarization come later, and
# need an Apple Developer Program membership.
codesign --force --sign - "$APP" 2>/dev/null || echo "note: ad-hoc signing skipped"

echo "Built $APP"
