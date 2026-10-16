# DashCam Studio (Mac)

Receives footage from the iPhone app, lets you label what's in it, and feeds
two things back:

- **Road memory** — labelled signs become places the phone recalls by GPS and
  direction on later drives, whether or not the camera reads them.
- **Training dataset** — labelled frames in Create ML object-detection format,
  for the on-device detector.

## Run it

```bash
swift run --package-path MacHelper DashCamStudio
```

Allow the incoming-connection prompt the first time. Footage lands in
`~/Movies/DashCam/`.

Prefer no window? The headless receiver speaks the same protocol:

```bash
swift run --package-path MacHelper dashcam-offload-helper
```

## The workflow

1. **Receive** — the receiver starts automatically. Offload from the phone
   (Settings ▸ Mac Offload). Every file is SHA-256 verified before the phone
   is allowed to delete its copy; the transfer log shows each one.
2. **Label** — pick a clip in the sidebar. Scrub or step frame-by-frame, pick
   a class from the palette, drag a box on the frame. Drag to move, drag the
   corner handle to resize, Delete box to remove. Classes with a value (speed
   limit, school, hump, city, fire station) get a value field — fill it in,
   because that's what the phone will display.
3. **Export road memory** (⇧⌘E) — writes `Export/roadmemory.json`.
4. **Import on the phone** — Settings ▸ Mac Offload ▸ **Import road memory
   from Mac**. Imported features are treated as hand-placed: authoritative,
   and never overwritten by detection.
5. **Export training dataset** (⇧⌘D) — writes `Export/TrainingData-<stamp>/`
   with one JPEG per labelled frame plus `annotations.json`.

## What makes a label become road memory

Only classes that carry a **road-memory type** (speed limit, school, hump,
hospital, bike route, city limit, fire station), and only when the clip has a
telemetry sidecar with a GPS fix and heading at that moment. The transport bar
shows a 📍 when the current frame has a fix — no pin means a label there can
still train the detector, but can't become a place.

Obstacles (bollards, cones, barriers, debris) and surface markings (green bike
lane paint, crosswalks, stop lines) are **training-only** by design — they
move or repaint, so pinning them to a map would age badly.

## Classes

Everything is data-driven in `~/Movies/DashCam/classes.json`, editable from the
**Classes** button. Add a machine name, display name, group, colour, and
optionally a road-memory type. New obstacle types need no rebuild.

## Layout

```
~/Movies/DashCam/
  2026-08-03/               received clips + telemetry sidecars
  Labels/                   one .labels.json per clip
  Export/
    roadmemory.json         served to the phone at GET /memory
    TrainingData-<stamp>/   images + annotations.json
  classes.json
```

## Protocol

| Endpoint | Purpose |
|---|---|
| `GET /ping` | Discovery check; returns service name and destination |
| `GET /memory` | The phone pulls `roadmemory.json` |
| `POST /upload` | Upload with `X-File-Name` and `X-SHA256`; replies `{"verified":true}` only after the checksum matches |

Advertised on Bonjour as `_dashcam-offload._tcp` on port 42841.
