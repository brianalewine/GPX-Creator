#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)
APP="$PWD/GPX Creator.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/GPXCreator" "$APP/Contents/MacOS/GPXCreator"
cp "Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>GPXCreator</string><key>CFBundleIdentifier</key><string>com.brian.gpxcreator</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundleName</key><string>GPX Creator</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1.0</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/><key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict></dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
