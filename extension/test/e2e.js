// End-to-end test in real Chromium (run under a virtual display):
//   xvfb-run -a node test/e2e.js
// Loads dist/, records the screen with the fake microphone, checks the
// on-page controls, stops, and checks the editor: the video plays, trimming
// and downloading work, and the recording is kept as a draft. Saves
// screenshots to test-output/.
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const dist = path.join(root, 'dist');
const out = path.join(root, 'test-output');
fs.mkdirSync(out, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (ok, what) => {
  console.log(`${ok ? '✓' : '✗'} ${what}`);
  if (!ok) failures++;
};

// A page to record: something moving, and a button to click.
const server = http.createServer((req, res) => {
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.end(`<!doctype html><title>Demo dashboard</title>
<style>body{font:18px system-ui;margin:0;background:#f4f6fb}header{background:#190096;color:#fff;padding:18px 28px;font-weight:700}
main{padding:28px;display:grid;grid-template-columns:repeat(3,1fr);gap:18px}.card{background:#fff;border-radius:14px;padding:22px;box-shadow:0 6px 20px -12px #0003}
.bar{height:120px;display:flex;align-items:flex-end;gap:10px}.bar i{flex:1;background:#0080ff;border-radius:6px 6px 0 0;animation:g 1.6s ease-in-out infinite alternate}
@keyframes g{from{height:30%}to{height:95%}}button{font:inherit;padding:10px 18px;border-radius:10px;border:0;background:#0080ff;color:#fff}</style>
<header>Northwind · Sales overview</header><main>
<div class="card"><b>Revenue</b><h2>$48.2k</h2><button id="b">Export report</button></div>
<div class="card"><div class="bar"><i></i><i style="animation-delay:.3s"></i><i style="animation-delay:.6s"></i><i style="animation-delay:.9s"></i></div></div>
<div class="card"><b>Orders</b><h2>1,204</h2></div></main>`);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const site = `http://127.0.0.1:${server.address().port}/`;

const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'sr-ext-'));
const context = await chromium.launchPersistentContext(profile, {
  headless: false,
  viewport: { width: 1280, height: 800 },
  acceptDownloads: true,
  args: [
    `--disable-extensions-except=${dist}`,
    `--load-extension=${dist}`,
    '--use-fake-ui-for-media-stream',
    '--use-fake-device-for-media-stream',
    '--auto-select-tab-capture-source-by-title=Demo dashboard',
    '--auto-accept-this-tab-capture',
    '--window-size=1280,860',
  ],
});

try {
  let sw = context.serviceWorkers()[0] || await context.waitForEvent('serviceworker', { timeout: 15000 });
  const extId = new URL(sw.url()).host;
  check(Boolean(extId), `extension loaded (${extId})`);
  const ext = (p) => `chrome-extension://${extId}/${p}`;

  // Grant the fake mic/camera to the extension, as the permissions page would.
  const perm = await context.newPage();
  await perm.goto(ext('permissions.html?mic=1&camera=1'));
  await perm.waitForFunction(() => /Done/.test(document.getElementById('msg').textContent), null, { timeout: 10000 }).catch(() => {});
  check(/Done/.test(await perm.locator('#msg').textContent().catch(() => '')), 'permissions page gets the microphone and camera');

  // Popup (opened as a page for the screenshot).
  const popup = await context.newPage();
  await popup.setViewportSize({ width: 340, height: 600 });
  await popup.goto(ext('popup.html'));
  await popup.waitForSelector('#start');
  await popup.screenshot({ path: path.join(out, 'popup.png') });
  check(await popup.locator('#start').isVisible(), 'popup shows Start recording');

  const page = await context.newPage();
  await page.goto(site);
  await page.bringToFront();
  const tabId = await popup.evaluate(async (url) => (await chrome.tabs.query({ url })).at(0)?.id, site);

  // "This tab". Chrome only lets an extension record a tab directly after
  // the user clicks it (or presses its shortcut), which automation can't do,
  // so here the extension falls back to Chrome's share prompt, which the test
  // browser answers by picking the demo tab.
  await page.bringToFront();
  await sleep(300);
  const r = await popup.evaluate((id) => chrome.runtime.sendMessage({ type: 'start', source: 'tab', tabId: id, mic: true, camera: true, effects: true }), tabId);
  check(r?.ok, `recording this tab starts${r?.ok ? '' : `: ${r?.error}`}`);
  const mode = 'tab';

  await page.bringToFront();
  await sleep(1500);
  const overlay = await page.evaluate(() => Boolean(document.querySelector('screen-recorder-overlay')));
  check(overlay, 'on-page controls, halo and camera bubble appear on the page');
  for (const [x, y] of [[200, 200], [420, 260], [640, 330], [180, 250]]) {
    await page.mouse.move(x, y, { steps: 12 });
    await sleep(250);
  }
  await page.mouse.click(180, 250);
  await sleep(300);
  await page.screenshot({ path: path.join(out, 'recording-page.png') });

  const state = await popup.evaluate(() => chrome.runtime.sendMessage({ type: 'state' }));
  check(state?.value?.status === 'recording', `state is recording (${state?.value?.status})`);
  await sleep(1500);
  await popup.evaluate(() => chrome.runtime.sendMessage({ type: 'pause' }));
  await sleep(800);
  await popup.evaluate(() => chrome.runtime.sendMessage({ type: 'resume' }));
  await sleep(1500);

  const editorOpened = context.waitForEvent('page', { predicate: (p) => p.url().includes('editor.html'), timeout: 60000 });
  await popup.evaluate(() => chrome.runtime.sendMessage({ type: 'stop' }));
  const editor = await editorOpened;
  await editor.setViewportSize({ width: 1280, height: 800 });
  await editor.waitForSelector('#editor:not([hidden])', { timeout: 30000 });
  await editor.waitForFunction(() => document.getElementById('video').readyState >= 2, null, { timeout: 20000 });
  const info = await editor.evaluate(() => {
    const v = document.getElementById('video');
    return { duration: v.duration, w: v.videoWidth, h: v.videoHeight, items: document.querySelectorAll('#list .item').length, status: document.getElementById('status').textContent };
  });
  console.log('  recording:', JSON.stringify(info));
  check(Number.isFinite(info.duration) && info.duration > 3 && info.duration < 9, `video has a proper length (${info.duration?.toFixed?.(2)} s; paused time left out)`);
  check(info.w > 0 && info.h > 0, `video has pictures (${info.w}×${info.h})`);
  check(info.items === 1 && info.status === 'Draft', 'kept in Recordings as a Draft');
  await editor.screenshot({ path: path.join(out, 'editor.png') });

  // Play: the big button starts the video.
  await editor.click('#big');
  await sleep(1200);
  const playing = await editor.evaluate(() => ({ t: document.getElementById('video').currentTime, paused: document.getElementById('video').paused, big: document.getElementById('big').hidden }));
  check(!playing.paused && playing.t > 0.3 && playing.big, `big Play button plays it (at ${playing.t.toFixed(2)} s)`);
  await editor.click('#play');

  // Mic sound is in the file.
  const meta = await editor.evaluate(async () => {
    const id = location.hash.slice(1);
    const db = await new Promise((r) => { const q = indexedDB.open('screen-recorder'); q.onsuccess = () => r(q.result); });
    const rec = await new Promise((r) => { const q = db.transaction('recordings').objectStore('recordings').get(id); q.onsuccess = () => r(q.result); });
    return { mime: rec.mime, hasAudio: rec.hasAudio, size: rec.blob.size };
  });
  console.log('  stored:', JSON.stringify(meta));
  const bytes = await editor.evaluate(async () => {
    const id = location.hash.slice(1);
    const db = await new Promise((r) => { const q = indexedDB.open('screen-recorder'); q.onsuccess = () => r(q.result); });
    const rec = await new Promise((r) => { const q = db.transaction('recordings').objectStore('recordings').get(id); q.onsuccess = () => r(q.result); });
    const buf = new Uint8Array(await rec.blob.arrayBuffer());
    let s = ''; for (let i = 0; i < buf.length; i += 0x8000) s += String.fromCharCode(...buf.subarray(i, i + 0x8000));
    return btoa(s);
  });
  fs.writeFileSync(path.join(out, `recording.${meta.mime.includes('mp4') ? 'mp4' : 'webm'}`), Buffer.from(bytes, 'base64'));
  check(meta.hasAudio, 'microphone recorded');

  // Trim to 1.0–3.0 s and download MP4.
  await editor.evaluate(() => {
    const v = document.getElementById('video');
    v.currentTime = 1;
    document.getElementById('set-start').click();
    v.currentTime = 3;
    document.getElementById('set-end').click();
  });
  await sleep(700);
  await editor.click('#download');
  await editor.waitForFunction(() => /Saved to|failed/.test(document.getElementById('msg').textContent), null, { timeout: 120000 });
  const msg = await editor.locator('#msg').textContent();
  check(/Saved to/.test(msg), `download works (${msg.slice(0, 70)}…)`);
  const dl = await editor.evaluate(() => new Promise((r) => {
    const look = () => chrome.downloads.search({ orderBy: ['-startTime'], limit: 1 }, ([d]) => (d && d.state === 'complete' ? r(d) : setTimeout(look, 300)));
    look();
  }));
  // (The test browser stores downloads under an internal id; real Chrome uses Downloads/Screen Recorder/<name>.mp4.)
  check(dl.fileSize > 1000 && dl.state === 'complete', `file saved (${Math.round(dl.fileSize / 1024)} KB)`);
  // Measure the downloaded file with ffprobe: length and codec.
  try {
    const info = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_entries', 'format=duration:stream=codec_name,codec_type', '-of', 'json', dl.filename]).toString());
    const v = info.streams.find((x) => x.codec_type === 'video');
    const a = info.streams.find((x) => x.codec_type === 'audio');
    const secs = Number(info.format.duration);
    // Chose 1.0–3.0 s: about 2 s (a fast trim starts on the next keyframe).
    check(secs > 1.6 && secs < 2.4, `downloaded clip is trimmed (${secs.toFixed(2)} s)`);
    check(v?.codec_name === 'h264' && Boolean(a), `downloaded MP4 is H.264 with sound (${v?.codec_name} + ${a?.codec_name})`);
  } catch (error) {
    console.log(`  (ffprobe not available to measure the download: ${error.message.split('\n')[0]})`);
  }
  const status = await editor.locator('#status').textContent();
  check(status === 'Downloaded', 'marked Downloaded, still in Recordings');
  await editor.screenshot({ path: path.join(out, 'editor-downloaded.png') });

  // Popup now lists it.
  await popup.reload();
  await popup.waitForSelector('#list .item', { timeout: 5000 }).catch(() => {});
  check(await popup.locator('#list .item').count() === 1, 'popup lists the recording');
  await popup.screenshot({ path: path.join(out, 'popup-with-recording.png') });

  const upgrade = await context.newPage();
  await upgrade.setViewportSize({ width: 900, height: 820 });
  await upgrade.goto(ext('upgrade.html'));
  await upgrade.waitForSelector('#buy:not([hidden])', { timeout: 10000 }).catch(() => {});
  await upgrade.screenshot({ path: path.join(out, 'upgrade.png') });
  check(await upgrade.locator('.plan').count() === 2, 'upgrade page shows $5 monthly and $50 lifetime');
  console.log(`  mode used: ${mode}`);

  // Window or screen: Chrome's share prompt (a fake screen in tests).
  await page.bringToFront();
  const d = await popup.evaluate((id) => chrome.runtime.sendMessage({ type: 'start', source: 'desktop', tabId: id, mic: true, camera: false, effects: true }), tabId);
  check(d?.ok, `window/screen recording starts${d?.ok ? '' : `: ${d?.error}`}`);
  if (d?.ok) {
    await sleep(2500);
    const second = context.waitForEvent('page', { predicate: (p) => p.url().includes('editor.html'), timeout: 60000 });
    await popup.evaluate(() => chrome.runtime.sendMessage({ type: 'stop' }));
    const ed2 = await second;
    await ed2.waitForFunction(() => document.querySelectorAll('#list .item').length === 2, null, { timeout: 20000 }).catch(() => {});
    await ed2.waitForFunction(() => document.getElementById('video').readyState >= 2, null, { timeout: 20000 }).catch(() => {});
    const n = await ed2.evaluate(() => ({ items: document.querySelectorAll('#list .item').length, d: document.getElementById('video').duration }));
    check(n.items === 2 && n.d > 1.5, `screen recording saved too; both kept (${n.items} recordings, ${n.d?.toFixed?.(1)} s)`);
    await ed2.screenshot({ path: path.join(out, 'editor-two.png') });
  }
} catch (error) {
  failures++;
  console.error('✗ test crashed:', error);
} finally {
  await context.close();
  server.close();
}
console.log(failures ? `${failures} problem(s)` : 'all extension checks passed');
process.exit(failures ? 1 : 0);
