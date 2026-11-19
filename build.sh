#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
# Use a stable signing identity for local rebuilds so Keychain recognizes updates.
# Other machines can build without a developer account or certificate.
PREFERRED_SIGNING_IDENTITY="178E4AF50200B7948C1ABEF29BC99694C1A710DB"
SIGNING_IDENTITY="${GPX_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  AVAILABLE_IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
  if [[ "$AVAILABLE_IDENTITIES" == *"$PREFERRED_SIGNING_IDENTITY"* ]]; then
    SIGNING_IDENTITY="$PREFERRED_SIGNING_IDENTITY"
  else
    SIGNING_IDENTITY="-"
  fi
fi
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
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>GPXCreator</string><key>CFBundleIdentifier</key><string>com.brian.gpxcreator</string><key>CFBundleIconFile</key><string>AppIcon.icns</string><key>CFBundleIconName</key><string>AppIcon</string><key>CFBundleVersion</key><string>2</string><key>CFBundleName</key><string>GPX Creator</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1.0</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/><key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoadsInWebContent</key><true/></dict></dict></plist>
PLIST
echo "Signing with: $SIGNING_IDENTITY"
codesign --force --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"
