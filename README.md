# Screen Recorder

A desktop app for **Windows** and **Linux** that records any rectangle of the screen (another window, a browser, a terminal — not this window). Built with Flutter.

## Windows

**Install:** download `ScreenRecorder-Setup.exe` from the [Releases page](../../releases/tag/windows-latest), run it, and a **Screen Recorder** shortcut appears on your desktop. No admin rights, no FFmpeg install — everything is bundled.

> The installer isn't code-signed, so Windows SmartScreen may say *"Windows protected your PC"*. Click **More info → Run anyway**.

**Windows-only extras** (toggle them on the home screen):

| Feature | What it does |
| --- | --- |
| **Cursor highlight** | A yellow halo follows the mouse and every click sends out a ripple (yellow = left, blue = right). It's visible live on screen while you record and is captured into the video. |
| **Auto-zoom follows mouse** | After you stop, the video is re-rendered so the camera smoothly zooms in around your clicks, pans to follow the cursor, and zooms back out when you go idle. Zoom strength is adjustable (1.2×–3×). Recordings with no clicks are left as-is. |

Notes:

- The capture area is the monitor the app window is on. To record another monitor, drag the app there before pressing **Start Recording**.
- The app's own window is excluded from recordings (Windows 10 2004 or newer).
- Microphone uses the first DirectShow audio input (your default mic in most setups).
- Auto-zoom adds a processing step after you press Stop; longer recordings take longer.

**Build the installer yourself:** every push to `main` runs `.github/workflows/windows-installer.yml`, which builds the app, bundles FFmpeg 7.1.1 and the VC++ runtime, and packages `ScreenRecorder-Setup.exe` with Inno Setup (`installer/screen_recorder.iss`). Locally on Windows: `flutter build windows --release`, copy `ffmpeg.exe` into `build\windows\x64\runner\Release\ffmpeg\`, then `iscc installer\screen_recorder.iss`.

---

## Linux

**Supported sessions**

| Desktop | Session | What it uses |
| --- | --- | --- |
| GNOME | Wayland | GNOME Shell screencast |
| GNOME | X11 | FFmpeg `x11grab` |
| Sway, Hyprland, and other wlroots compositors | Wayland | `wf-recorder` |
| KDE Plasma | X11 | FFmpeg `x11grab` |

KDE Plasma on **Wayland** is not supported. Log into a Plasma **X11** session instead.

---

## 1. Install Flutter

You need Flutter **3.11** or newer with Linux desktop enabled.

```bash
flutter --version
flutter config --enable-linux-desktop
flutter doctor
```

`flutter doctor` should report **Linux toolchain** as ready. If it does not, install the compiler stack:

**Ubuntu / Debian**

```bash
sudo apt update
sudo apt install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev
```

**Fedora**

```bash
sudo dnf install -y clang cmake ninja-build pkgconf-pkg-config gtk3-devel xz-devel
```

**Arch**

```bash
sudo pacman -S --needed clang cmake ninja pkgconf gtk3 xz
```

---

## 2. Install capture tools

The app always needs **FFmpeg** on `PATH`. Extra packages depend on the desktop.

### Everyone (required)

**Ubuntu / Debian**

```bash
sudo apt install -y ffmpeg
```

**Fedora**

```bash
sudo dnf install -y ffmpeg
```

**Arch**

```bash
sudo pacman -S --needed ffmpeg
```

Check:

```bash
ffmpeg -version
```

### GNOME (Wayland)

Needed so the compositor can capture and encode:

```bash
# Ubuntu / Debian
sudo apt install -y libglib2.0-bin gstreamer1.0-plugins-good gstreamer1.0-plugins-base \
  xdg-desktop-portal xdg-desktop-portal-gnome

# Fedora
sudo dnf install -y glib2 gstreamer1-plugins-good gstreamer1-plugins-base \
  xdg-desktop-portal xdg-desktop-portal-gnome

# Arch
sudo pacman -S --needed glib2 gst-plugins-good gst-plugins-base \
  xdg-desktop-portal xdg-desktop-portal-gnome
```

`gdbus` (from GLib) talks to GNOME’s screencast service. The portal packages show the screenshot / screen-share prompt when you pick a region.

### Sway / Hyprland

```bash
# Ubuntu / Debian
sudo apt install -y wf-recorder xdg-desktop-portal xdg-desktop-portal-wlr

# Fedora
sudo dnf install -y wf-recorder xdg-desktop-portal xdg-desktop-portal-wlr

# Arch
sudo pacman -S --needed wf-recorder xdg-desktop-portal xdg-desktop-portal-wlr
```

### Microphone (optional)

PulseAudio or PipeWire must be running. On most modern distros PipeWire is already there. Grant microphone access when the OS asks.

---

## 3. Get the project and run it

```bash
cd screen_recorder_app
flutter pub get
flutter run -d linux
```

The window should open as **Screen Recorder**. Use **Start Recording** or `Ctrl+Shift+R`.

---

## 4. Allow screen capture on the OS

The first time you select a region or start a recording, Linux will ask for permission. Approve it, or the capture stays black / fails.

### GNOME

1. Click **Start Recording**.
2. If a **Share your screen** / **Screenshot** dialog appears, choose the display (or whole screen) and allow it.
3. If nothing appears, open **Settings → Privacy & Security → Screen Cast** (wording varies by GNOME version) and allow this app.
4. For the microphone toggle, allow **Microphone** in the same Privacy settings if asked.

You can reset a stuck “deny” later:

```bash
# Forget previous screenshot-portal answers (GNOME)
flatpak permission-reset com.example.screen_recorder_app 2>/dev/null || true
```

If that does nothing, log out and back in after installing the portal packages.

### Sway / Hyprland

1. Make sure `xdg-desktop-portal-wlr` is running in the session.
2. Allow the share dialog when you start a recording.
3. Confirm `wf-recorder` works on its own:

```bash
wf-recorder -g "0,0 640x480" -f /tmp/test.mp4
# Ctrl+C to stop, then play /tmp/test.mp4
```

### X11 (GNOME or KDE)

No portal dialog. FFmpeg grabs the X display directly. A compositor (GNOME, KWin, Picom, …) should be running so the overlay can dim the desktop.

---

## 5. Record

1. Click **Start Recording** (`Ctrl+Shift+R`).
2. Drag a rectangle of at least **100×100** pixels. Optionally turn on the microphone switch.
3. Confirm to start capture.
4. **Pause / resume:** `Ctrl+Shift+Space`. **Stop:** `Ctrl+Shift+S`.
5. Pick a save location in the file dialog.

---

## 6. Optional: build a standalone copy

For a folder you can copy to another Linux machine of the **same architecture**:

```bash
flutter build linux --release
```

The app lives in:

```text
build/linux/x64/release/bundle/
```

Run it with:

```bash
./build/linux/x64/release/bundle/screen_recorder_app
```

That other machine still needs **FFmpeg** (and **wf-recorder** on Sway/Hyprland). GNOME Wayland still needs the GNOME screencast + portal packages from step 2.

To add it to the app menu, copy the bundle somewhere permanent (for example `~/Apps/screen_recorder`) and create `~/.local/share/applications/screen-recorder.desktop`:

```ini
[Desktop Entry]
Name=Screen Recorder
Exec=/home/YOUR_USER/Apps/screen_recorder/screen_recorder_app
Icon=video-display
Type=Application
Categories=AudioVideo;Recorder;
Terminal=false
```

Replace `YOUR_USER` with the real home path. Then:

```bash
update-desktop-database ~/.local/share/applications
```

---

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| “FFmpeg is not installed” | Install `ffmpeg` and restart the app. Confirm `which ffmpeg`. |
| “GNOME screencast service … was not available” | Use a GNOME session, install the GNOME packages in step 2, or switch to an X11 GNOME session. |
| “No Wayland region recorder” on Sway/Hyprland | Install `wf-recorder`. |
| KDE Wayland error | Log out and choose a **Plasma (X11)** session. |
| Screenshot / region picker is black or cancelled | Allow the portal dialog; install `xdg-desktop-portal` plus the matching backend (`-gnome` or `-wlr`). |
| Microphone silent | Enable the in-app mic switch before capture; check the default input in Sound settings. |
| `flutter doctor` Linux toolchain failed | Install clang, cmake, ninja, pkg-config, and `libgtk-3-dev` (step 1). |

Confirm the session type if you are unsure:

```bash
echo "$XDG_SESSION_TYPE"   # wayland or x11
echo "$XDG_CURRENT_DESKTOP"
```
