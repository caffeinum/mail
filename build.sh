#!/bin/bash
# Builds build/Post.app around the SwiftPM binary, ad-hoc signed.
#   ./build.sh           release
#   ./build.sh debug
# Only the command line tools are needed; the 26.5 SDK because the 27 SDK's
# SwiftUI macros need a plugin the CLT don't ship.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${1:-release}"
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
swift build -c "$CONFIG" --product Mail
swift build -c "$CONFIG" --product mailctl
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP=build/Post.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Mail" "$APP/Contents/MacOS/Post"
cp "$BIN/mailctl" build/mailctl
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.caffeinum.mail</string>
  <key>CFBundleName</key><string>Post</string>
  <key>CFBundleDisplayName</key><string>Post</string>
  <key>CFBundleExecutable</key><string>Post</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "$APP"
