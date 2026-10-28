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


// Structured data (read by Google and AI assistants) must parse, and its FAQ
// must match the questions on the page.
{
  const block = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
  if (!block) fail('index.html has no JSON-LD');
  else {
    try {
      const data = JSON.parse(block[1]);
      const faq = data['@graph'].find((n) => n['@type'] === 'FAQPage');
      const onPage = [...html.matchAll(/<span class="pm"[^>]*><\/span>([\s\S]*?)<\/button>/g)]
        .map((m) => m[1].replace(/<[^>]+>/g, '').replace(/&amp;/g, '&').trim());
      const inData = faq.mainEntity.map((q) => q.name);
      if (JSON.stringify(onPage) !== JSON.stringify(inData)) fail('JSON-LD FAQ is out of date with the FAQ on the page');
      else console.log(`✓ JSON-LD: ${inData.length} FAQ entries match the page`);
    } catch (error) {
      fail(`JSON-LD does not parse: ${error.message}`);
    }
  }
}

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
for (const name of ['robots.txt', 'sitemap.xml', 'llms.txt']) {
  if (fs.existsSync(path.join(root, name))) fs.copyFileSync(path.join(root, name), path.join(out, name));
}
console.log('✓ copied index.html, pro.html, admin.html, assets/, robots.txt, sitemap.xml and llms.txt to public/');
console.log('build ok');
