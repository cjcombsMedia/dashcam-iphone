#!/bin/bash
# Rebuild DashCam Studio and install it into /Applications.
set -e
cd "$(dirname "$0")"
APP="/Applications/DashCam Studio.app"

echo "Building release…"
swift build -c release --package-path MacHelper

echo "Installing to $APP…"
pkill -f "DashCam Studio.app" 2>/dev/null || true
sleep 1
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp MacHelper/.build/release/DashCamStudio "$APP/Contents/MacOS/DashCamStudio"

# Icon: generated once from the shared camera+car mark.
if [ ! -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  TMP=$(mktemp -d)
  swift Tools/make_icon.swift "$TMP/icon.png" >/dev/null
  mkdir -p "$TMP/icon.iconset"
  for size in 16 32 64 128 256 512; do
    sips -z $size $size "$TMP/icon.png" --out "$TMP/icon.iconset/icon_${size}x${size}.png" >/dev/null 2>&1
    sips -z $((size*2)) $((size*2)) "$TMP/icon.png" --out "$TMP/icon.iconset/icon_${size}x${size}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$TMP/icon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$TMP"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleDisplayName</key><string>DashCam Studio</string>
	<key>CFBundleExecutable</key><string>DashCamStudio</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>com.cjcombs.dashcamstudio</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>DashCam Studio</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSLocalNetworkUsageDescription</key>
	<string>DashCam Studio receives dash cam footage from your iPhone over your local network.</string>
	<key>NSBonjourServices</key><array><string>_dashcam-offload._tcp</string></array>
	<key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1
echo "Installed. Launching…"
open "$APP"
