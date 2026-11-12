#!/usr/bin/env bash
# Build DashCam Studio, the Mac labeling studio that receives footage from the iPhone app,
# and install it to /Applications.
#   ./install-mac.sh          build what is checked out
#   ./install-mac.sh --pull   update main first from the highest-priority account this clone
#                             has a remote for (TANSTAFL, then GitHub); refuses over
#                             uncommitted changes or a branch other than main
# CJ's MacTools > App Updater runs it with --pull. Every install writes a receipt for it.
# The app is a Swift package (MacHelper/), assembled into a bundle here and signed ad hoc.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DashCam Studio"
BUNDLE_ID="com.cjcombs.dashcamstudio"
EXECUTABLE="DashCamStudio"
BUILT="build/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# The highest-priority ghx account (the order `ghx accounts` lists: TANSTAFL, then GitHub
# personal, then work) that has a remote in the clone at $1. Prints nothing if none does.
pull_account() {  # $1 = clone folder
  local mapped a
  mapped=$(cd "$1" && ghx status 2>/dev/null | awk '/^REMOTE +ACCOUNT/ {t=1; next} t && NF >= 3 {print $2}')
  for a in $(ghx accounts 2>/dev/null | awk 'NR > 1 && NF >= 3 && $1 !~ /^•/ {print $1}'); do
    if printf '%s\n' "$mapped" | grep -qx "$a"; then echo "$a"; return 0; fi
  done
}

pull_main() {
  local branch account
  if [ -n "$(git status --porcelain)" ]; then
    git status --short
    die "this clone has uncommitted changes. Commit or stash them, then run again."
  fi
  branch=$(git rev-parse --abbrev-ref HEAD)
  [ "$branch" = "main" ] || die "this clone is on branch '$branch'. Switch it to main, then run again."
  command -v ghx >/dev/null 2>&1 || die "--pull needs ghx (~/.local/bin/ghx) to pick the right account."
  account=$(pull_account .)
  [ -n "$account" ] || die "this clone has no remote for any ghx account (ghx status shows them). Add one with ghx link."
  say "Pulling main from $account"
  ghx pull "$account" main --ff-only
}

case "${1:-}" in
  --pull) pull_main ;;
  "") ;;
  -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
  *) die "unknown option '$1' (use --pull or nothing)" ;;
esac

[ "$(uname -s)" = "Darwin" ] || die "this script is for macOS."
# SwiftUI's macros and actool (the Icon Composer icon) ship only in Xcode.
if [ -z "${DEVELOPER_DIR:-}" ] && [[ "$(xcode-select -p 2>/dev/null)" == *CommandLineTools* ]]; then
  [ -d /Applications/Xcode.app ] || die "Xcode is required. Install it from the App Store, open it once, then run again."
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

say "Building $APP_NAME (release)"
swift build -c release --package-path MacHelper --product "$EXECUTABLE"

say "Assembling $BUILT"
rm -rf "$BUILT"
mkdir -p "$BUILT/Contents/MacOS" "$BUILT/Contents/Resources"
cp "MacHelper/.build/release/$EXECUTABLE" "$BUILT/Contents/MacOS/$EXECUTABLE"
cat > "$BUILT/Contents/Info.plist" <<'PLIST'
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
printf 'APPL????' > "$BUILT/Contents/PkgInfo"

# Icon: the black-and-yellow Icon Composer document, compiled on every install.
# Absolute paths (actool works through a shared daemon with its own working folder).
# IBToolNeverDeque=1 makes actool start its own ibtoold instead of reusing one another build
# left running, which fails on Icon Composer documents; it also fails with stdin closed.
say "Compiling the app icon"
ROOT="$PWD"
mkdir -p build
IBToolNeverDeque=1 xcrun actool "$ROOT/MacHelper/AppIcon.icon" \
  --compile "$ROOT/$BUILT/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$ROOT/build/icon-info.plist" < /dev/null > "$ROOT/build/actool.log" 2>&1 || true
# actool can exit 0 when it fails, so check that it produced the icon.
if [ ! -f "$BUILT/Contents/Resources/AppIcon.icns" ]; then
  cat build/actool.log >&2
  die "actool didn't compile MacHelper/AppIcon.icon (needs Xcode 26 or later)."
fi

codesign --force --deep --sign - "$BUILT" >/dev/null 2>&1

running() { pgrep -f "$APP_NAME.app/Contents/MacOS/$EXECUTABLE" >/dev/null 2>&1; }
if running; then
  say "Quitting the running copy"
  osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do running || break; sleep 0.5; done
  running && die "$APP_NAME is still open. Quit it, then run again."
fi

say "Installing to $DEST"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"
# Receipt for CJ's MacTools > App Updater: which commit this Mac now runs.
( set +e
  dir="$HOME/Library/Application Support/CJ Apps/receipts"; mkdir -p "$dir"
  top=$(git rev-parse --show-toplevel)
  dirty=false; [ -n "$(git -C "$top" status --porcelain)" ] && dirty=true
  printf '{"bundleId":"%s","commit":"%s","branch":"%s","dirty":%s,"source":"%s","installedAt":"%s","mac":"%s"}\n' \
    "$BUNDLE_ID" "$(git -C "$top" rev-parse HEAD)" "$(git -C "$top" rev-parse --abbrev-ref HEAD)" "$dirty" \
    "$top" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(scutil --get ComputerName)" > "$dir/$BUNDLE_ID.json"
) || true
# Finder and the Dock cache icons per path; re-register so a new icon shows at once.
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true
open "$DEST"

say "Installed and opened $APP_NAME ($(git rev-parse --short HEAD))."
