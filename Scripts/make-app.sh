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

echo "Building FileFerry ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product FileFerry

BINARY="$(swift build -c "$CONFIGURATION" --product FileFerry --show-bin-path)/FileFerry"

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
    <key>NSHumanReadableCopyright</key><string>MIT licensed</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. A Developer ID signature and notarization come later, and
# need an Apple Developer Program membership.
codesign --force --sign - "$APP" 2>/dev/null || echo "note: ad-hoc signing skipped"

echo "Built $APP"
