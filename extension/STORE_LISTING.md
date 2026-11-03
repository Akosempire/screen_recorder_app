# Chrome Web Store listing: Screen Recorder

Upload `ScreenRecorder-Chrome-Extension.zip` (from the latest GitHub release) in the
Chrome Web Store Developer Dashboard. The same zip works for Microsoft Edge Add-ons.

## Store listing

**Name:** Screen Recorder: tab, window & screen

**Summary** (max 132 characters):
Record a tab, window or your screen with your voice and face. Click highlights, trim, and download MP4. Nothing is uploaded.

**Category:** Productivity → Tools · **Language:** English

**Description:**

Record anything in your browser and share a video people can actually follow.

• Record this tab (with its sound), any window, or your whole screen
• Your voice from the microphone, and your face in a bubble you can drag anywhere
• A yellow cursor halo and click ripples on web pages, so viewers see exactly what you click
• Pause and resume; a small on-page bar shows the time, with Finish and Discard
• Every recording is kept as a draft in your browser until you delete it: nothing is lost if you record again
• Play it back, trim the start and end, rename it, and download MP4 (H.264) or WebM
• Private: recording, editing and saving happen on your computer. Your videos are never uploaded.

Free to try: every feature works for recordings up to 3 minutes. Pro removes the limit ($5 a month or $50 once) and also unlocks the Screen Recorder desktop app for Windows, Mac and Linux.

Shortcut: Alt+Shift+R starts or stops recording the current tab.

**Website:** https://screenrecorderapp.vercel.app
**Privacy policy:** https://screenrecorderapp.vercel.app/privacy
**Support:** https://github.com/Akosempire/screen_recorder_app/issues

**Screenshots** (1280×800, from the build's `extension-*.png` release files):
1. `extension-recording-page.png`: recording a page with the halo, camera bubble and controls
2. `extension-editor-downloaded.png`: the editor with playback, trim and download
3. `extension-upgrade.png` (crop to 1280×800 or 640×400 if the store asks)

## Privacy tab

**Single purpose:** Record the user's browser tab, a window or the screen (with optional microphone and webcam), and let them trim and download the video.

**Permission justifications:**
- `tabCapture`: records the tab the user chooses, after they click the extension or press its shortcut.
- `offscreen`: runs the recorder in an offscreen document (Manifest V3 has no other place to record media).
- `storage`, `unlimitedStorage`: keeps recordings (which can be large) and settings in the browser until the user deletes them.
- `scripting`: shows the recording controls, cursor halo, click ripples and camera bubble on the page being recorded.
- `downloads`: saves the exported video to the user's Downloads folder.
- Host permission `<all_urls>`: needed to show the on-page controls and effects on whichever site the user records, and to check the Pro licence with screenrecorderapp.vercel.app. Page content is never read or collected.

**Remote code:** No. All code, including FFmpeg (WebAssembly), is inside the package.

**Data usage** (tick):
- Personally identifiable information: **yes**, only the name and email a user types when buying Pro (sent to our checkout).
- Everything else: **no**. Recordings, website content, browsing history and activity are not collected.
- Certify: not sold to third parties; not used for unrelated purposes; not used for credit decisions.
