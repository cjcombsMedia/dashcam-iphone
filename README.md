# Dash Cam (iPhone) — Iteration 1

Native SwiftUI dash cam for iOS 17+, iPhone only, landscape-primary. No third-party dependencies.

## Open & build

```bash
open DashCam.xcodeproj
```

Or from the command line (works even when `xcode-select` points at CommandLineTools):

```bash
export DEVELOPER_DIR=/Applications/Xcode.app
xcodebuild -project DashCam.xcodeproj -scheme DashCam \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Unit tests + UI smoke test
xcodebuild -project DashCam.xcodeproj -scheme DashCam \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

To run on your iPhone: select the DashCam target → Signing & Capabilities → pick your team, then run. Camera, GPS, and the accelerometer only work on a real device.

## Targets

- **DashCam** — the app.
- **DashCamTests** — unit tests: storage budget/pruning (mock file system), auto-tag detector, telemetry sidecar format.
- **DashCamUITests** — Simulator smoke flow: startup modal → debug sample clips → library Loop/Saved/Tagged → player tag markers → full-disk warning banner.

## Architecture

MVVM with separated services (`DashCam/Services/`):

- `CaptureService` — AVCaptureSession + per-segment AVAssetWriter. HEVC 30 fps, QuickTime movie fragments every 2 s so an interruption never corrupts more than the last few seconds. Handles adaptive exposure/HDR/low-light, ISO-based night detection, thermal 4K→HD override, and interruption finalize/resume.
- `StorageManager` — two-folder model (LOOP overwritable / SAVED protected) and the 75% storage budget, recalculated before each segment; oldest LOOP pruned first; SAVED never touched. Unit-testable via the `FileSystem` protocol.
- `LocationService` / `MotionService` / `TelemetryRecorder` — GPS/heading, impact & hard-braking auto-tags (pure `AutoTagDetector` logic), 1 Hz JSON sidecars that travel with their segment.
- `TagStore` — tagging moves a segment + sidecar from LOOP to SAVED.

Recordings live in `Documents/Loop` and `Documents/Saved`; clip metadata in SwiftData.

## Debug tools (Settings → Debug)

- **Simulate full disk** — clamps reported free space to 0 to exercise pruning, the low-capacity banner, and the stop-recording path.
- **Simulate impact** — fires the auto-tag pipeline while recording.
- **Add sample clip / tagged sample clip** — generates synthetic footage so the library/player work in the Simulator.

## Iteration 2 additions

- **Camera selector** (Wide / Ultra Wide / Telephoto / Front, per device) on the main screen next to the resolution selector, locked while recording; Settings shows a **live thumbnail** of the selected camera so you can preview exactly what will be recorded.
- **Tag/timeline sync**: tags are timestamped with the segment's media-time clock (not wall clock) and clamped to the encoded duration, so scrubber markers land exactly where the tag fired. The player also starts immediately instead of waiting for the fragmented file's duration scan.
- **Satellite indicator**: green/yellow/red GPS fix status next to the speed readout on both the overlay and the HUD; degrades to "No GPS fix" when the fix is stale. GPS needs no network — the app is fully offline.
- **Gyro heading**: continuous gyro+magnetometer fused heading backs up the compass/GPS course for the display and the telemetry sidecar.
- **Always location**: settings toggle ("Use location all the time", default on) that requests Always authorization; a yellow chip on the main screen flags when it isn't granted and deep-links to Settings.
- **Screen controls**: DIM button (drops straight into the HUD; the HUD keeps its own TAG button), and a day/night toggle — day forces ~90% brightness, night drops very low and engages the amber palette.

## Iteration 3 additions (device-focused)

- **On-device diagnostics** (`Documents/Logs`, visible in Files ▸ On My iPhone ▸ Dash Cam ▸ Logs): daily error/info logs plus crash capture — uncaught exceptions and fatal signals (including Swift traps) write a `pending-crash.log` that the next launch promotes to `crash-<timestamp>.log`. All capture/storage/library failure paths log here. A Diagnostics section in Settings shows file counts.
- **Rotation lock while recording**: the interface freezes in whatever orientation recording started in; stop recording to rotate.
- **Emergency-light auto-tag** (fully offline, on-device): every ~6th frame's native YCbCr chroma plane is sparsely sampled for saturated red/blue clusters; flashing red+blue (or a rapid blue-only strobe) auto-tags with a 30 s cooldown and draws a **green detection box** with an "EMERGENCY LIGHTS" label over the preview. Steady brake lights and red-only turn signals are filtered out by the flash-pattern requirement. Toggle in Settings ▸ Auto-tag.
- **Infinity focus lock**: every selected camera locks its lens at the far limit (`setFocusModeLocked(lensPosition: 1.0)`), so focus never hunts off the road.

## Mac auto-offload

When the phone joins the same network as a Mac running the helper, the app can upload **all** footage (Loop and Saved, with telemetry sidecars) to `~/Movies/DashCam/<date>/` and clear it from the phone — each file is deleted only after the Mac verifies its SHA-256 checksum.

**Mac side** (one-time):

```bash
swift run --package-path MacHelper          # run in a terminal, or:
swift build -c release --package-path MacHelper
cp MacHelper/.build/release/dashcam-offload-helper /usr/local/bin/
```

macOS will ask once to allow incoming network connections. To run it permanently, add a LaunchAgent that starts `dashcam-offload-helper` at login.

**iPhone side**: Settings ▸ Mac Offload ▸ enable "Auto-offload to Mac" (or tap "Offload now"). iOS will ask once for Local Network permission. Uploads run in a background session, so locking the phone mid-transfer is fine; offload never starts while recording.

## Notes & intentional deviations

- Segments are written as fragmented **QuickTime (.mov)** via `movieFragmentInterval` rather than literal `.mp4` — movie fragments are guaranteed for QuickTime containers and give the same corruption protection the spec asks for. Switching to `.mp4` is a one-line change in `CaptureService.beginSegment` if preferred.
- Tagging confirms instantly (haptic + flash) and records the tag; the physical file move to SAVED happens seconds later when the in-flight segment finalizes, since a file being written can't be moved.
- Hard-braking detection uses orientation-agnostic acceleration magnitude sustained ≥0.5 s, so it works regardless of how the phone is mounted.

## Device test checklist (needs real hardware)

1. 30-minute session at HD and 4K → segments + sidecars for each (acceptance #1).
2. Resolution selector locked while recording; applies next session (#2).
3. HUD dims after the timeout, tap restores, red indicator pulses in both modes (#3).
4. Tag from full and HUD modes; drive over a speed bump for the impact auto-tag (#4).
5. Day/tunnel/night drive: exposure adapts, night palette + moon icon engage (#7).
