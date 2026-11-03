// Builds the extension into dist/ (ready for "Load unpacked") and zips it
// into screen-recorder-extension.zip (for the Chrome Web Store / Edge Add-ons).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const src = path.join(root, 'src');
const dist = path.join(root, 'dist');
const nm = path.join(root, 'node_modules', '@ffmpeg');

fs.rmSync(dist, { recursive: true, force: true });
fs.cpSync(src, dist, { recursive: true });

// FFmpeg (WebAssembly): the library's ES modules and the single-threaded core.
const ffDir = path.join(dist, 'vendor', 'ffmpeg');
const coreDir = path.join(dist, 'vendor', 'ffmpeg-core');
fs.mkdirSync(ffDir, { recursive: true });
fs.mkdirSync(coreDir, { recursive: true });
for (const f of fs.readdirSync(path.join(nm, 'ffmpeg', 'dist', 'esm'))) {
  if (f.endsWith('.js')) fs.copyFileSync(path.join(nm, 'ffmpeg', 'dist', 'esm', f), path.join(ffDir, f));
}
for (const f of ['ffmpeg-core.js', 'ffmpeg-core.wasm']) {
  fs.copyFileSync(path.join(nm, 'core', 'dist', 'esm', f), path.join(coreDir, f));
}
fs.writeFileSync(path.join(dist, 'vendor', 'LICENSES.txt'),
  'ffmpeg.wasm (@ffmpeg/ffmpeg, @ffmpeg/core) — MIT licence for the JavaScript, FFmpeg itself under LGPL/GPL.\n' +
  'Source: https://github.com/ffmpegwasm/ffmpeg.wasm and https://ffmpeg.org\n');

// Every file the manifest and pages point at must exist.
const manifest = JSON.parse(fs.readFileSync(path.join(dist, 'manifest.json'), 'utf8'));
const refs = new Set([
  manifest.background.service_worker,
  manifest.action.default_popup,
  ...Object.values(manifest.icons),
  ...Object.values(manifest.action.default_icon),
  ...manifest.web_accessible_resources.flatMap((w) => w.resources),
  'content.js', 'offscreen.html', 'editor.html', 'upgrade.html', 'permissions.html',
]);
for (const html of fs.readdirSync(dist).filter((f) => f.endsWith('.html'))) {
  const text = fs.readFileSync(path.join(dist, html), 'utf8');
  for (const m of text.matchAll(/(?:src|href)="([^"#?:]+)"/g)) refs.add(m[1]);
}
let missing = 0;
for (const ref of refs) {
  if (!fs.existsSync(path.join(dist, ref))) { console.error(`✗ missing ${ref}`); missing++; }
}
if (missing) process.exit(1);

const zip = path.join(root, 'screen-recorder-extension.zip');
fs.rmSync(zip, { force: true });
execFileSync('zip', ['-q', '-r', '-X', zip, '.'], { cwd: dist });
const mb = (fs.statSync(zip).size / 1e6).toFixed(1);
console.log(`✓ dist/ built (${refs.size} files checked), screen-recorder-extension.zip ${mb} MB, version ${manifest.version}`);
