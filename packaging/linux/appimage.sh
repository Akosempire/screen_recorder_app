#!/usr/bin/env bash
# Builds ScreenRecorder-Linux-x64.AppImage from the Flutter Linux bundle.
#   packaging/linux/appimage.sh <out-dir>
# Run on the OLDEST distro we support (Ubuntu 22.04) after
# `flutter build linux --release`: the AppImage carries its own libraries
# (GTK, libmpv, FFmpeg...) and only needs a glibc at least that new.
set -euo pipefail

OUT="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="build/linux/x64/release/bundle"
APP_ID="app.screenrecorder.ScreenRecorder"
TOOLS="$(mktemp -d)"
APPDIR="$(mktemp -d)/AppDir"
mkdir -p "$OUT" "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" \
  "$APPDIR/usr/share/icons/hicolor/512x512/apps"

# Tools (pinned "continuous" releases from the AppImage projects).
curl -fsSL -o "$TOOLS/linuxdeploy" \
  https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
curl -fsSL -o "$TOOLS/linuxdeploy-plugin-gtk.sh" \
  https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh
curl -fsSL -o "$TOOLS/appimagetool" \
  https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x "$TOOLS"/*
export PATH="$TOOLS:$PATH"
export APPIMAGE_EXTRACT_AND_RUN=1   # no FUSE needed on the build machine

# The Flutter bundle (binary + lib/ + data/) lives in usr/bin.
cp -a "$BUNDLE/." "$APPDIR/usr/bin/"

# FFmpeg travels with the app: a static build (x11grab + PulseAudio).
curl -fsSL -o "$TOOLS/ffmpeg.tar.xz" https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
tar -xJf "$TOOLS/ffmpeg.tar.xz" -C "$TOOLS"
cp "$TOOLS"/ffmpeg-*-static/ffmpeg "$APPDIR/usr/bin/ffmpeg"
"$APPDIR/usr/bin/ffmpeg" -hide_banner -devices 2>/dev/null | grep -E "x11grab|pulse|alsa|v4l2" || true

sed "s|^Exec=.*|Exec=screen_recorder_app %U|" "$HERE/$APP_ID.desktop" \
  > "$APPDIR/usr/share/applications/$APP_ID.desktop"
cp "$HERE/screen-recorder.png" "$APPDIR/usr/share/icons/hicolor/512x512/apps/screen-recorder.png"

libs=()
for so in "$APPDIR"/usr/bin/lib/*.so; do libs+=(--library "$so"); done

DEPLOY_GTK_VERSION=3 linuxdeploy --appdir "$APPDIR" \
  --executable "$APPDIR/usr/bin/screen_recorder_app" \
  "${libs[@]}" \
  --desktop-file "$APPDIR/usr/share/applications/$APP_ID.desktop" \
  --icon-file "$APPDIR/usr/share/icons/hicolor/512x512/apps/screen-recorder.png" \
  --plugin gtk

# The Flutter binary looks for lib/ and data/ next to itself; make sure its
# own libraries win over any copies linuxdeploy made.
patchelf --set-rpath '$ORIGIN/lib:$ORIGIN/../lib' "$APPDIR/usr/bin/screen_recorder_app"
# Plugins (media_kit, window_manager...) must also find the libraries
# linuxdeploy bundled in usr/lib (libmpv and its codecs).
for so in "$APPDIR"/usr/bin/lib/*.so; do
  patchelf --set-rpath '$ORIGIN:$ORIGIN/../../lib' "$so"
done
# Fail the build if anything the app needs is still missing (ignoring the
# few system libraries every desktop has, which AppImages never bundle).
missing=$(LD_LIBRARY_PATH="$APPDIR/usr/lib" ldd "$APPDIR/usr/bin/screen_recorder_app" "$APPDIR"/usr/bin/lib/*.so | grep "not found" | sort -u || true)
if [ -n "$missing" ]; then echo "Missing libraries:"; echo "$missing"; exit 1; fi
ls "$APPDIR/usr/lib" | grep -E "mpv|avcodec" || { echo "libmpv was not bundled"; exit 1; }

ARCH=x86_64 appimagetool --no-appstream "$APPDIR" "$OUT/ScreenRecorder-Linux-x64.AppImage"
chmod +x "$OUT/ScreenRecorder-Linux-x64.AppImage"
ls -la "$OUT"
