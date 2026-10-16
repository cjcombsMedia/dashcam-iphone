# Dash Cam — User Guide

A dash cam for iPhone: continuous loop recording with GPS telemetry, tagging,
on-device road detection, and one-tap offload to your Mac. Everything works
offline — no account, no network, no subscription.

---

## 1. Before each drive

1. Mount the phone with a clear windshield view and **plug it into power**.
2. Open Dash Cam. The **"Before you record"** checklist appears every time the
   app starts — tap **OK, I understand** to unlock the controls.
3. Tap the big **red record button** (bottom left).

The app is landscape-only and keeps the screen awake while recording. Leaving
the app fully stops recording and all services; returning starts a fresh
session with the checklist again.

---

## 2. The main screen

### Top row (left to right)
| Control | What it does |
|---|---|
| 🖼 Library | Your recordings |
| ⚙️ Settings | Disabled while recording |
| 📍 Yellow chip | Appears when location isn't set to "Always" — tap to fix |
| 🔄 Camera | Wide / Ultra Wide / Telephoto / Front (locked while recording) |
| 🎤 Mic | Mute or unmute audio (locked while recording) |
| HD / 4K | Resolution (locked while recording; applies to the next session) |

### Right edge
| Control | What it does |
|---|---|
| ⚠️ Yellow triangle | Only when hot — 4K was auto-dropped to HD to protect the phone |
| ☀️ / 🌙 | Day mode (90% brightness) / Night mode (very dim + amber palette) |
| ◐ DIM | Switch to the dim HUD immediately |
| ⚙️ Sliders | Manual focus & brightness panel |

### Bottom
- **Record button** (left) — start/stop.
- **TAG button** (center, while recording) — saves the moment.
- **REC indicator** (right) — pulses while recording.

### The gray telemetry box (bottom left)
Speed · compass heading · GPS coordinates · GPS signal status · time of day ·
ride roughness (🟢🟡🟠🔴) · phone temperature (❄️🌡️🥵🔥).

---

## 3. Recording, tagging, and storage

- Video is saved in **3-minute segments** (adjustable) as H.264 `.mp4`, with a
  matching `.json` telemetry file recorded at 1 Hz.
- **Tapping TAG** marks the moment and **protects that segment** so it's never
  overwritten. You get a buzz and a green confirmation.
- **Automatic tags**: hard impacts, hard braking, and emergency lights.
- **Loop recording**: footage is capped at 75% of available space. When full,
  the **oldest unprotected clips** are deleted first — protected clips are
  never auto-deleted.
- If space runs out entirely, recording stops with a loud alert.

---

## 4. Dim mode (screensaver)

After 3 minutes without a tap (adjustable), or when you press **DIM**, the
screen goes black with just large **speed and heading**, the GPS chip, a TAG
button, and the REC dot. These drift and bounce around the screen so nothing
burns in. **Tap anywhere** to return to the camera view.

---

## 5. Road detection

While driving, the app watches the road entirely on-device and shows mock signs
in the upper-left, each with its own chime:

| Detected | On screen | Duration |
|---|---|---|
| Speed limit | White speed sign (number flips when it changes) | Until a new limit is read |
| Speed hump / bump | Flashing yellow BUMP sign | 12 s |
| School zone | Fluorescent SCHOOL sign | 25 s |
| Hospital | Blue **H** — **tap it for directions to the nearest ER** | 45 s |
| Bike route | Green BIKE ROUTE sign | 30 s |
| City limits | "Welcome to …" banner | 15 s |
| Traffic signal | Signal mock with the live color | Only when slowing or stopped |
| Cyclist | Flashing green arrow + chime | Until 3 s after passing |
| Pedestrian | Cyan box around them | While in view |
| Emergency lights | Green box + automatic tag | While detected |

**Why signals only appear when slowing:** they'd be noise at cruising speed.
Detection still runs constantly and **every signal change is written into the
recording's telemetry**, so if there's ever an incident the file proves what
the light was.

Turn all of this off in **Settings ▸ Road Detection**.

### Road memory — it learns your routes

Every sign the camera confirms is remembered by **location and direction of
travel**. On later drives the sign appears from memory as you approach, even
if the camera can't read it — at night, in glare, or in rain. Signs shown from
memory carry a small cyan **M**.

- A detected feature must be **seen twice** before it's used, so one bad read
  never sticks.
- A sign is tied to the direction you were driving — the opposite side of the
  road is a separate entry.

**Settings ▸ Road Detection ▸ Road memory** lists everything learned, nearest
first:

| Action | How |
|---|---|
| Fix a wrong value | Tap the row, type the correct one |
| Delete a wrong entry | Swipe left → Delete |
| Turn one off without deleting | Swipe left → Disable |
| Add a sign the camera can't read | **Add here** (top left) — saves at your current spot and heading |
| Start over | **Forget everything** |

Anything you edit or add by hand becomes authoritative — detection will never
overwrite it.

---

## 6. Library and playback

Open with the 🖼 button. One list, newest first, with an **All / Tagged**
filter. A green 🔒 marks protected clips.

- **Tap a clip** → full-screen replay that looks like the live view: telemetry
  box, road signs, and detection boxes all replayed at the right moments.
- **Tap the video** → show/hide controls (back, Export, scrubber, play/pause).
  Yellow marks on the scrubber are your tags — tap a tag chip to jump there.
- **Swipe a row** → Delete or Protect.
- **Long-press a row** → Protect, Export to Photos, Share with overlay, Share
  original, Delete.

Every delete asks for confirmation.

### Clearing out a lot at once

Tap **Select** (top left) to enter selection mode:

- Tap rows to check them, or tap **Select All**.
- The bottom bar shows how many are selected and how much space they use.
- **Delete (n)** removes them all after one confirmation, which tells you how
  much space you'll free and warns if any are protected 🔒.
- **Cancel** leaves selection mode.

Tip: switch the filter to **Tagged** first if you want to select only tagged
clips — Select All follows whatever filter is showing.

### Export options
Tap **Export** in the player and choose:

| Mode | What you get | Speed |
|---|---|---|
| **Video only** | Clean footage | Fastest |
| **Basic overlay** | Telemetry text burned along the bottom | Medium |
| **Full graphical** | Everything the live screen showed, burned in | Slowest |

Then pick AirDrop, Save to Files, Mail, Messages, etc. Originals are never
modified.

---

## 7. Sending footage to your Mac

**One-time setup on the Mac:**

```bash
swift run --package-path MacHelper
```

Allow the incoming-connection prompt. Footage lands in `~/Movies/DashCam/`.

**On the phone:** Settings ▸ Mac Offload ▸ turn on **Auto-offload to Mac**
(or tap **Offload now**). Allow the Local Network prompt once.

When your phone joins the same network, all clips upload and are **deleted from
the phone only after the Mac verifies each file's checksum**. Uploads continue
if you lock the phone, and never start while recording.

---

## 8. Settings quick reference

| Section | Contents |
|---|---|
| **Units** | mph or km/h |
| **Camera** | Which lens records |
| **Location** | "Use location all the time" + current access level |
| **Recording** | Segment length, record audio |
| **Display** | How long before dimming to the HUD |
| **Auto-tag** | Impact sensitivity, emergency-light detection |
| **Road Detection** | Signs & signals on/off, **Detection test / training** |
| **Startup** | Show the checklist at launch |
| **Storage** | Hours of recording available, space used |
| **Mac Offload** | Auto-offload, helper status, Offload now |
| **Diagnostics** | Where logs live and how many exist |
| **Debug** | Simulate full disk, simulate impact, add sample clips |

---

## 9. Detection test / training

**Settings ▸ Road Detection ▸ Detection test / training**

Pick any photo or video from your library and the app runs the same detection
it uses while driving, then reports:

- which signs it matched,
- which signal colors fired,
- **every piece of text it actually read**,
- a plain-English diagnosis when nothing matched.

Use this to check detection without driving. **Save frame as training data**
stores the image for future model training.

---

## 10. Files and troubleshooting

Everything is browsable in **Files ▸ On My iPhone ▸ Dash Cam**:
- `Loop/` and `Saved/` — your footage and telemetry files
- `Logs/` — daily logs and crash reports
- `TrainingData/` — frames saved from Detection Test

| Problem | Fix |
|---|---|
| Can't press record | Acknowledge the startup checklist first |
| Settings button greyed out | Stop recording — it's locked during capture |
| Speed shows `0` / `--` | Wait for GPS lock (watch the signal chip) |
| Blurry footage | Manual panel → **AUTO** focus; tap the preview to focus a point |
| "iPhone is hot" triangle | Normal in sun — 4K dropped to HD to keep recording |
| Low-space warning | Export or delete protected clips, or offload to your Mac |
| Detection missing signs | Run Detection Test on a photo of that sign |
| Something's wrong | Check `Logs/` — errors and crashes are recorded there |

---

## Good to know

- All processing is **on-device**. Nothing is uploaded anywhere except your own
  Mac, when you ask.
- **Rotation is locked** to landscape and frozen while recording.
- Focus stays on the road automatically; it never hunts on raindrops.
- Optical + software stabilization are always on.
