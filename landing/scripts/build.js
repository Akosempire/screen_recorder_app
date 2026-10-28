// `npm run build`: the site is static HTML plus Vercel functions, so there is
// nothing to bundle. This checks that every function loads and exports a
// handler, and that every local file index.html points at exists.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
let failed = 0;
const fail = (msg) => { failed++; console.error(`✗ ${msg}`); };

for (const file of fs.readdirSync(path.join(root, 'api')).filter((f) => f.endsWith('.js')).sort()) {
  try {
    const mod = await import(pathToFileURL(path.join(root, 'api', file)).href);
    if (typeof mod.default !== 'function') fail(`api/${file} has no default handler`);
    else console.log(`✓ api/${file}`);
  } catch (error) {
    fail(`api/${file} failed to load: ${error.message}`);
  }
}

const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const refs = new Set([...html.matchAll(/(?:src|href)="(\/[^"#?]+)"/g)].map((m) => m[1]));
let assets = 0;
for (const ref of refs) {
  if (ref.startsWith('/api/')) continue;
  if (!fs.existsSync(path.join(root, ref))) fail(`index.html references missing ${ref}`);
  else assets++;
}
console.log(`✓ index.html: ${assets} local assets found`);

if (failed) {
  console.error(`build failed: ${failed} problem(s)`);
  process.exit(1);
}

// Vercel serves static files from public/ when a build step exists.
// Copy only the site itself, so source files (lib/, scripts/, db/) stay private.
const out = path.join(root, 'public');
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out);
fs.copyFileSync(path.join(root, 'index.html'), path.join(out, 'index.html'));
fs.copyFileSync(path.join(root, 'pro.html'), path.join(out, 'pro.html'));
fs.copyFileSync(path.join(root, 'admin.html'), path.join(out, 'admin.html'));
fs.cpSync(path.join(root, 'assets'), path.join(out, 'assets'), { recursive: true });
for (const name of ['robots.txt', 'sitemap.xml']) {
  if (fs.existsSync(path.join(root, name))) fs.copyFileSync(path.join(root, name), path.join(out, name));
}
console.log('✓ copied index.html, pro.html, admin.html, assets/, robots.txt and sitemap.xml to public/');
console.log('build ok');
