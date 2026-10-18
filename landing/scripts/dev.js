// `npm start`: serves the site and runs api/*.js like Vercel does, for local testing.
// Reads .env.local / .env (written by `neon deploy`).
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { loadEnvFiles } from './env-files.js';

loadEnvFiles();
const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const port = Number(process.env.PORT) || 3000;
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript',
  '.png': 'image/png', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.ico': 'image/x-icon' };

function vercelRes(res) {
  res.status = (code) => { res.statusCode = code; return res; };
  res.json = (body) => {
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.end(JSON.stringify(body));
    return res;
  };
  return res;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://local');
  try {
    const api = url.pathname.match(/^\/api\/([a-z0-9-]+)$/);
    if (api) {
      const file = path.join(root, 'api', `${api[1]}.js`);
      if (!fs.existsSync(file)) { res.statusCode = 404; return res.end('Not found'); }
      let raw = '';
      for await (const chunk of req) raw += chunk;
      if (raw && /json/.test(req.headers['content-type'] || '')) {
        try { req.body = JSON.parse(raw); } catch { req.body = raw; }
      } else req.body = raw || undefined;
      const { default: handler } = await import(pathToFileURL(file).href);
      return await handler(req, vercelRes(res));
    }
    let file = path.join(root, decodeURIComponent(url.pathname));
    if (!file.startsWith(root)) { res.statusCode = 403; return res.end(); }
    if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
    if (!fs.existsSync(file)) { res.statusCode = 404; return res.end('Not found'); }
    res.setHeader('Content-Type', types[path.extname(file)] || 'application/octet-stream');
    fs.createReadStream(file).pipe(res);
  } catch (error) {
    console.error(error);
    if (!res.headersSent) { res.statusCode = 500; res.end('Server error'); }
  }
});

server.listen(port, () => console.log(`Landing page on http://localhost:${port}`));
