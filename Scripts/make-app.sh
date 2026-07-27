#!/usr/bin/env bash
# Assembles Conduit.app around the SPM-built executable.
#
# SwiftPM cannot produce a macOS .app bundle, and hand-maintaining an
# .xcodeproj means a merge-conflict magnet in a repo that otherwise builds
# with `swift build`. This script bridges the gap: one binary, one Info.plist.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Conduit.app"
VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo "0.1.0-dev")"

# Command Line Tools does not ship Swift Testing, and its SDK differs from
# Xcode's. Prefer Xcode when it is present.
if [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

echo "Building Conduit ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product Conduit

BINARY="$(swift build -c "$CONFIGURATION" --product Conduit --show-bin-path)/Conduit"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Conduit"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Conduit</string>
    <key>CFBundleDisplayName</key><string>Conduit</string>
    <key>CFBundleIdentifier</key><string>dev.gopalkannan.conduit</string>
    <key>CFBundleExecutable</key><string>Conduit</string>
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
