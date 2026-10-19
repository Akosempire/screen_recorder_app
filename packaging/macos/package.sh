#!/usr/bin/env bash
# Adds FFmpeg to the built .app, ad-hoc signs it, and makes the .dmg.
#   packaging/macos/package.sh <ffmpeg-binary> <out-dir>
# Run after `flutter build macos --release`.
#
# Not notarized (no Apple Developer ID yet): the first open needs
# System Settings -> Privacy & Security -> Open Anyway. Apple Silicon only
# runs signed code, so everything gets an ad-hoc signature.
set -euo pipefail

FFMPEG="$1"
OUT="$2"
APP="build/macos/Build/Products/Release/Screen Recorder.app"
mkdir -p "$OUT"
[ -d "$APP" ] || { echo "No app at $APP"; ls build/macos/Build/Products/Release; exit 1; }

cp "$FFMPEG" "$APP/Contents/MacOS/ffmpeg"
chmod 755 "$APP/Contents/MacOS/ffmpeg"
xattr -cr "$APP"

# Sign inside-out: the helper, the frameworks, then the app.
codesign --force --sign - "$APP/Contents/MacOS/ffmpeg"
find "$APP/Contents/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) \
  -exec codesign --force --sign - {} \; 2>/dev/null || true
codesign --force --sign - \
  --entitlements macos/Runner/Release.entitlements \
  "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
lipo -info "$APP/Contents/MacOS/Screen Recorder" "$APP/Contents/MacOS/ffmpeg"

STAGE="$(mktemp -d)/Screen Recorder"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/First open - read me.txt" <<'TXT'
Install: drag Screen Recorder onto the Applications folder.

First open: macOS will say it can't check the app for malicious software,
because it isn't notarized by Apple yet. Click Done, then open
System Settings > Privacy & Security, scroll down and click "Open Anyway".

Recording: the first time you record, allow Screen Recording in
System Settings > Privacy & Security > Screen Recording, then quit and
reopen Screen Recorder.
TXT

rm -f "$OUT/ScreenRecorder-macOS.dmg"
hdiutil create -volname "Screen Recorder" -srcfolder "$STAGE" -ov -format UDZO \
  "$OUT/ScreenRecorder-macOS.dmg"
ls -la "$OUT"
