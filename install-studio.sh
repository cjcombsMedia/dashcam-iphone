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

# Icon: the black-and-yellow Icon Composer document, compiled on every install so a
# redesign reaches an existing copy. Needs Xcode 26's actool (not just Command Line Tools).
# IBToolNeverDeque=1 keeps actool off an ibtoold daemon another build may have started.
if ! xcrun --find actool >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
ICON_TMP=$(mktemp -d)
rm -f "$APP/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/Assets.car"
IBToolNeverDeque=1 xcrun actool MacHelper/AppIcon.icon \
  --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$ICON_TMP/icon-info.plist" >"$ICON_TMP/actool.log" 2>&1
# actool exits 0 even when it fails, so check that it produced the icon.
if [ ! -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  cat "$ICON_TMP/actool.log"
  echo "Icon compile failed (needs Xcode 26)." >&2
  exit 1
fi
rm -rf "$ICON_TMP"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleDisplayName</key><string>DashCam Studio</string>
	<key>CFBundleExecutable</key><string>DashCamStudio</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIconName</key><string>AppIcon</string>
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
# Nudge Finder and the Dock to drop the cached old icon.
touch "$APP"
echo "Installed. Launching…"
open "$APP"
