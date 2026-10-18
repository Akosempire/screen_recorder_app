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
console.log('build ok');
