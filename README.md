# Screen Recorder

Native **Linux desktop** screen-region recorder. The Flutter UI is the control
surface; capture is performed by **FFmpeg** (`x11grab` on X11) or
**wf-recorder** (Wayland / wlroots). This is not a browser app and does not
use `getDisplayMedia` or `MediaRecorder`.

## Features

- Select an arbitrary rectangle (create, drag, resize from 8 handles)
- Optional **microphone** audio (switch on the region selector before Record)
- Pause / resume (paused time is omitted from the final file)
- Native GTK save dialog (directory, filename, `.mp4` / `.mkv`)
- Keyboard shortcuts
- Multi-monitor coordinates, including negative monitor offsets

## Requirements

| Dependency | When | Why |
| --- | --- | --- |
| Flutter SDK (stable, Linux desktop enabled) | Build | Compiles the GTK application |
| GTK 3 development libraries | Build | Flutter Linux embedding |
| CMake, Ninja, Clang | Build | Linux toolchain |
| **FFmpeg** with `libx264` | Runtime | X11 capture, encoding, and segment merge |
| **wf-recorder** | Runtime on Wayland | Region capture on wlroots compositors |
| **grim** (optional) | Runtime on Wayland | Selector snapshot on wlroots compositors |
| **xdg-desktop-portal** | Runtime on GNOME/KDE Wayland | Selector snapshot (screenshot permission) |
| A compositing window manager | Runtime | Overlay and window positioning |

### Debian / Ubuntu

```bash
sudo apt update
sudo apt install ffmpeg x11-utils
# Wayland / wlroots (Sway, Hyprland, river, …)
sudo apt install wf-recorder grim
# Flutter Linux build toolchain (if not already installed)
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
```

### Fedora

```bash
sudo dnf install ffmpeg xrandr wf-recorder grim clang cmake ninja-build gtk3-devel
```

### Arch

```bash
sudo pacman -S ffmpeg wf-recorder grim
```

Confirm FFmpeg:

```bash
ffmpeg -version
```

Enable Flutter's Linux desktop target once:

```bash
flutter config --enable-linux-desktop
```

## Run

From the project root:

```bash
flutter pub get
flutter run -d linux
```

## Build a release

```bash
flutter pub get
flutter analyze
flutter test
flutter build linux
```

The release bundle is:

```text
build/linux/x64/release/bundle/screen_recorder_app
```

Run it:

```bash
./build/linux/x64/release/bundle/screen_recorder_app
```

## Usage

1. Click **Start Recording** (or press `Ctrl+Shift+R`).
2. The app hides, snapshots the desktop, and shows a fullscreen selector.
3. Click and drag to create a rectangle. Drag inside to move; use the handles
   to resize. Minimum size is **100×100** pixels.
4. Turn **Microphone** on if you want your voice in the video (off = video only).
   This uses the default PulseAudio / PipeWire source, not system audio.
5. Click **Record** (or press Enter). The overlay is hidden before capture
   starts so it is not in the video.
6. Use the compact control window:
   - **Pause** / **Resume** (`Ctrl+Shift+Space`)
   - **Stop** (`Ctrl+Shift+S`)
7. After Stop, the save dialog opens in the **last folder you saved to**
   (remembered across restarts). Cancelling the dialog **does not delete**
   the recording; the temp path is shown in the status line.

### Keyboard shortcuts

These work while the application window is focused. Bindings live in
`lib/services/shortcut_intents.dart` (`AppShortcutMap.defaults`) so they can
be changed without rewriting the UI.

| Shortcut | Action |
| --- | --- |
| `Ctrl+Shift+R` | Start / open region selector |
| `Ctrl+Shift+Space` | Pause or resume |
| `Ctrl+Shift+S` | Stop and save |
| `Esc` | Cancel region selection |
| `Enter` | Confirm selection and record |

Global (out-of-focus) shortcuts are not registered. Wayland does not allow
ordinary apps to grab global hotkeys without the XDG Global Shortcuts portal.

## Capture backends

### X11

Uses FFmpeg:

```text
ffmpeg -f x11grab -video_size WxH -framerate 30 -draw_mouse 1 \
  -i $DISPLAY+X,Y -an -c:v libx264 -preset ultrafast -crf 23 \
  -pix_fmt yuv420p output.mp4
```

With **Microphone** on, FFmpeg also captures PulseAudio `default` (mic) as AAC.

`$DISPLAY` and monitor geometry come from the environment and `xrandr`.
Coordinates are real X11 pixels, including negative offsets such as
`x = -1920`.

### Wayland

`x11grab` is **not** used to capture native Wayland windows. On GNOME it often
produces a **black** image (that was the black overlay).

**GNOME Shell (Wayland)** uses the built-in D-Bus API over a **persistent**
session-bus connection (GNOME stops capture if the caller disconnects):

```text
org.gnome.Shell.Screencast.ScreencastArea
```

Allow screen recording if GNOME prompts for permission. FFmpeg is still used
to turn the result into MP4.

**wlroots compositors** (Sway, Hyprland, river, …) use:

```text
wf-recorder -g "X,Y WxH" -r 30 -f output.mp4
```

With **Microphone** on, `-a` is added so `wf-recorder` records the default
PulseAudio source.

Install `wf-recorder` (and `grim` for the selector snapshot).

**KDE Plasma on Wayland** does not implement wlr-screencopy, and this app
does not use a KWin-specific recorder yet. Use a Plasma **X11** session or a
wlroots compositor.

The selector snapshot on Wayland uses the **XDG Screenshot portal**, then
`grim` (wlroots), then a one-frame GNOME Screencast. It never uses FFmpeg
`x11grab` (that captures a black XWayland root). GNOME's private
`org.gnome.Shell.Screenshot` API is blocked for regular apps.

### Mixed DPI / multi-monitor

The selector maps overlay-local coordinates **proportionally** onto the
virtual desktop bounding box from `screen_retriever` on Wayland, or `xrandr`
on X11.

Limitation: monitors with **different scale factors** in one session may
still be slightly off. If capture is shifted, check that the overlay covers
every monitor (some Wayland compositors refuse global window positioning).

## Pause / resume

FFmpeg `x11grab` and `wf-recorder` do not have a safe MP4 pause that drops
the paused interval. This app **stops the current capture process** on Pause
and **starts a new segment** on Resume. Stop concatenates segments with
FFmpeg (`-c copy`, re-encode if needed). The paused wall-clock time is not
in the output.

## Project layout

```text
lib/
├── main.dart
├── app.dart
├── models/
├── controllers/
├── services/
├── platform/          # X11ScreenRecorder, WaylandScreenRecorder
├── screens/
└── widgets/
```

The UI talks only to `RecordingController`. Capture backends implement
`ScreenRecorder` (`start` / `pause` / `resume` / `stop`).

## Tests

```bash
flutter test
```

Unit tests cover `ScreenRegion` (including negative coordinates), recording
state transitions, invalid transitions, save-dialog cancel, FFmpeg argument
construction, and `xrandr` parsing. Capture tests use a **fake**
`ScreenRecorder` so they do not need FFmpeg.

## Troubleshooting

**“FFmpeg is not installed”**  
Install FFmpeg and ensure `ffmpeg` is on `PATH`.

**“Wayland region recording requires wf-recorder”**  
Install `wf-recorder`, or switch to an X11 session.

**Black overlay / “Desktop preview unavailable”**  
The red box is still the recorded area. On GNOME Wayland the selector needs a
still from the screenshot portal — click **Allow** if GNOME asks. The app
keeps its window mapped during that prompt; hiding it first made GNOME cancel
the request and left the overlay black. On Sway/Hyprland install `grim`.

**Record does nothing / “GNOME started a screencast but wrote no video”**  
GNOME 46’s default screencast probes OpenH264 then a GL pipeline. If
`openh264enc` is missing (typical on Ubuntu), capture can report success and
still write an empty file. This app forces GNOME’s software VP8 path
(`videoconvert` + `vp8enc`). Allow screen recording if a prompt appears, then
try Record again.

**Black or empty video**  
The selected region may be off-screen, or (on Wayland) `wf-recorder` may not
support the compositor. Check logs from `flutter run -d linux`.

**“Screencast ended unexpectedly” / video is a still at 00:00**  
On GNOME Wayland the compositor stops capture if the D-Bus caller disconnects.
This app keeps that session-bus connection open for the whole recording. A
still-image file was the old one-shot `gdbus` path dying after the first frame.
Allow screen recording if GNOME prompts. The region selector no longer starts
a dummy screencast (that notification was from the snapshot, not the save).

**Permission / cannot open display**  
On X11, allow the user to connect to the X server. On Wayland, the compositor
must implement wlr-screencopy for `wf-recorder`.

**Controls appear in the recording**  
The compact control window is placed outside the selected rectangle when a
gap exists. If you record the entire desktop, hide the controls or use the
keyboard shortcuts.

**Not enough disk space**  
FFmpeg errors containing `No space left on device` are shown as a readable
message. Temp segments live under `/tmp/screen_recorder_*`.
