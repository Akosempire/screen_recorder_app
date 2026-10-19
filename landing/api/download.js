import { readToken } from '../lib/token.js';
import { hasDatabase, logDownload } from '../lib/db.js';

const RELEASE = 'https://github.com/Akosempire/screen_recorder_app/releases/latest/download';

// One file per platform, from the latest GitHub release.
export const FILES = {
  windows: 'ScreenRecorder-Setup.exe',
  mac: 'ScreenRecorder-macOS.dmg',
  linux: 'ScreenRecorder-Linux-x64.deb',
  'linux-tar': 'ScreenRecorder-Linux-x64.tar.gz',
};

export function fileUrl(os) {
  const name = FILES[os] || FILES.windows;
  if (name === FILES.windows && process.env.INSTALLER_URL) return process.env.INSTALLER_URL;
  return `${RELEASE}/${name}`;
}

// GET /api/download?t=<signed token>&os=windows|mac|linux|linux-tar
export default async function handler(req, res) {
  const secret = process.env.LINK_SECRET;
  const url = new URL(req.url, 'http://local');
  const email = secret ? readToken(url.searchParams.get('t') || '', secret) : null;

  if (!email) {
    res.statusCode = 410;
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    return res.end(expiredPage());
  }

  // Record the download in Supabase; never block the download on it.
  if (hasDatabase()) {
    const log = logDownload({
      email,
      country: req.headers['x-vercel-ip-country'] || '',
      userAgent: String(req.headers['user-agent'] || '').slice(0, 200),
    }).catch((error) => console.error('download log failed', error.message));
    await Promise.race([log, new Promise((resolve) => setTimeout(resolve, 2500))]);
  }

  res.statusCode = 302;
  res.setHeader('Location', fileUrl(url.searchParams.get('os') || 'windows'));
  res.setHeader('Cache-Control', 'no-store');
  return res.end();
}

function expiredPage() {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Link expired · Screen Recorder</title>
<style>body{font-family:"Segoe UI",system-ui,sans-serif;background:#EEF0F2;color:#15171A;display:grid;place-items:center;min-height:100vh;margin:0;padding:16px}
main{background:#fff;border:1px solid #D5D9DE;border-radius:18px;padding:32px;max-width:440px}
h1{font-size:24px;margin:0 0 8px}p{color:#3B4048;line-height:1.5;margin:0 0 20px}
a{display:inline-block;background:#15171A;color:#fff;text-decoration:none;font-weight:600;padding:12px 16px;border-radius:12px}</style></head>
<body><main><h1>This download link has expired</h1><p>Links work for 7 days. Enter your email again and we'll send a new one.</p><a href="/#get">Get a new link</a></main></body></html>`;
}
