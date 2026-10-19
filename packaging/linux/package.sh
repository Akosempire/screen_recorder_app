#!/usr/bin/env bash
# Packages the Flutter Linux bundle as a .deb and a .tar.gz.
#   packaging/linux/package.sh <version> <out-dir>
# Run after `flutter build linux --release`.
set -euo pipefail

VERSION="$1"
OUT="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="build/linux/x64/release/bundle"
APP_ID="app.screenrecorder.ScreenRecorder"
mkdir -p "$OUT"

[ -x "$BUNDLE/screen_recorder_app" ] || { echo "No Linux bundle at $BUNDLE"; exit 1; }

# ---- runtime dependencies, worked out from the binaries ----------------
# Every system library the app links against, mapped to its Debian package.
deps=$(
  { ldd "$BUNDLE/screen_recorder_app"; find "$BUNDLE/lib" -name '*.so*' -exec ldd {} \; ; } 2>/dev/null \
    | awk '/=> \// {print $3}' | sort -u \
    | grep -v "$(realpath "$BUNDLE")" \
    | while read -r lib; do dpkg -S "$(realpath "$lib")" 2>/dev/null || dpkg -S "$lib" 2>/dev/null || true; done \
    | cut -d: -f1 | sed 's/,.*//' | sort -u
) || true
depends="ffmpeg, xdg-utils"
for d in $deps; do
  case "$d" in libc6|libgcc-s1|libstdc++6|*-dev) ;; *) depends="$depends, $d";; esac
done
depends="libc6, libstdc++6, $depends"
echo "Depends: $depends"

# ---- .deb ---------------------------------------------------------------
ROOT="$(mktemp -d)/screen-recorder_${VERSION}_amd64"
mkdir -p "$ROOT/DEBIAN" "$ROOT/opt/screen-recorder" "$ROOT/usr/bin" \
  "$ROOT/usr/share/applications" "$ROOT/usr/share/icons/hicolor/512x512/apps"
cp -a "$BUNDLE/." "$ROOT/opt/screen-recorder/"
ln -s /opt/screen-recorder/screen_recorder_app "$ROOT/usr/bin/screen-recorder"
cp "$HERE/$APP_ID.desktop" "$ROOT/usr/share/applications/"
cp "$HERE/screen-recorder.png" "$ROOT/usr/share/icons/hicolor/512x512/apps/screen-recorder.png"
size=$(du -sk "$ROOT" | cut -f1)
cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: screen-recorder
Version: $VERSION
Section: video
Priority: optional
Architecture: amd64
Installed-Size: $size
Depends: $depends
Maintainer: Screen Recorder <hello@screenrecorderapp.cv>
Homepage: https://www.screenrecorderapp.cv/
Description: Screen recorder with click highlights, auto-zoom and quick edits
 Record any part of your screen with your microphone, then trim, cut, add a
 background and export an MP4. Everything stays on your computer.
CONTROL
cat > "$ROOT/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
command -v update-desktop-database >/dev/null && update-desktop-database -q /usr/share/applications || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t /usr/share/icons/hicolor || true
POST
chmod 755 "$ROOT/DEBIAN/postinst"
dpkg-deb --root-owner-group --build "$ROOT" "$OUT/ScreenRecorder-Linux-x64.deb"
dpkg-deb --info "$OUT/ScreenRecorder-Linux-x64.deb"

# ---- .tar.gz ------------------------------------------------------------
TAR="$(mktemp -d)/screen-recorder"
mkdir -p "$TAR"
cp -a "$BUNDLE/." "$TAR/"
cp "$HERE/README.txt" "$HERE/screen-recorder.png" "$TAR/"
tar -C "$(dirname "$TAR")" -czf "$OUT/ScreenRecorder-Linux-x64.tar.gz" screen-recorder
ls -la "$OUT"
