# Screen Recorder: browser extension

Chrome / Edge / Brave / Opera extension (Manifest V3). Records a tab, a window or the
whole screen with the microphone and a webcam bubble; cursor halo and click ripples on
web pages; every recording kept as a draft (IndexedDB); editor with playback, trim and
MP4/WebM download (FFmpeg compiled to WebAssembly, bundled). Same Pro licence as the app.

```
npm ci
npm run build                      # → dist/ (Load unpacked) and screen-recorder-extension.zip
node --test test/unit.test.js
xvfb-run -a node test/e2e.js       # real Chromium: record, edit, trim, download (screenshots in test-output/)
```

How a recording works:
- `background.js` (service worker): gets the tab from `chrome.tabCapture` (or, for a window/screen,
  lets the recorder show Chrome's share prompt), shows the on-page bar and effects (`content.js`),
  and opens the editor when it stops.
- `offscreen.js`: records with `MediaRecorder` (MP4/H.264 where Chrome supports it, else WebM),
  mixes tab sound and the mic, saves a piece to IndexedDB every second (crash-safe), then tidies
  the file with FFmpeg and notes its keyframes for fast, exact-to-the-second trims.
- `editor.html`: Recordings list, player, trim, download.

Publishing: see STORE_LISTING.md.
