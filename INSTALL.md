# Install DashCam Studio for Mac

DashCam Studio is the Mac side of the DashCam iPhone app: it receives footage from the phone
over the local network, lets you label it, and feeds road memory and training data back.
The iPhone app itself is built from `DashCam.xcodeproj` in Xcode.

The easy way: open **CJ's MacTools → App Updater** and press **Install** (or **Update**) next to
DashCam Studio. It runs the same script as below.

Repos (private): `cj/dashcam-iphone` on TANSTAFL (`tanstafl.devservers1313.space`, the source)
and `github.com/cjcombsMedia/dashcam-iphone` (the second copy).

## What you need

- macOS 14 or later on Apple silicon, and Xcode 26 or later from the App Store, opened once
  (SwiftUI's macros and `actool` for the Icon Composer icon ship only in Xcode).
- `ghx` with the TANSTAFL account (`ghx accounts` lists `tanstafl`).

No simulators are used.

## First-time install

```bash
cd ~/"CLAUDE CODE PROJECTS"
ghx clone tanstafl cj/dashcam-iphone DASHCAM-iPhone
cd DASHCAM-iPhone
ghx link personal cjcombsMedia/dashcam-iphone
./install-mac.sh
```

The first time it opens, macOS asks to allow incoming network connections: allow it, or the
phone can't send footage.

## Update to the latest version

From the repo folder:

```bash
./install-mac.sh --pull
```

`--pull` fast-forwards `main` through `ghx` from the highest-priority account the clone has a
remote for: TANSTAFL first, then GitHub. It stops if the clone has uncommitted changes or isn't
on `main`.

## What the script does

1. Builds the `DashCamStudio` product of the Swift package in `MacHelper/` (release).
2. Assembles `build/DashCam Studio.app`: the binary, its Info.plist, and the icon compiled from
   `MacHelper/AppIcon.icon` by `actool` (with `IBToolNeverDeque=1` and stdin from `/dev/null`),
   then signs it ad hoc.
3. Quits the running copy, copies the bundle to `/Applications/DashCam Studio.app` with
   `ditto`, writes a receipt for App Updater, refreshes the icon cache and opens the app.

`install-studio.sh`, the old name, now runs `install-mac.sh`.

## Check it's running

- The script ends with `Installed and opened DashCam Studio (<commit>)`.
- `pgrep -lf "DashCam Studio.app"` shows the process.

## Uninstall

Quit the app, then delete `/Applications/DashCam Studio.app`. Received footage in
`~/Movies/DashCam/` stays.
