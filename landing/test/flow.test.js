import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { execFileSync } from 'node:child_process';
import { makeToken, readToken } from '../lib/token.js';
import { connectionConfig } from '../lib/db.js';
import { downloadEmail } from '../lib/email.js';

// Minimal stand-ins for Vercel's req/res.
function mockRes() {
  const res = { statusCode: 200, headers: {}, body: undefined };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  res.setHeader = (k, v) => { res.headers[k.toLowerCase()] = v; };
  res.end = (b) => { res.body = b; return res; };
  return res;
}

test('token round-trip, tamper and expiry', () => {
  const t = makeToken('a@b.co', 's1', 1000);
  assert.equal(readToken(t, 's1', 2000), 'a@b.co');
  assert.equal(readToken(t, 'other', 2000), null);
  assert.equal(readToken(t.slice(0, -2) + 'xx', 's1', 2000), null);
  assert.equal(readToken(t, 's1', 1000 + 8 * 864e5), null);
  assert.equal(readToken('garbage', 's1'), null);
});

test('Supabase URLs keep TLS but drop sslmode; local URLs are untouched', () => {
  const s = connectionConfig('postgres://u:p@aws-0-eu-central-1.pooler.supabase.com:6543/postgres?sslmode=require&supa=base-pooler.x');
  assert.deepEqual(s.ssl, { rejectUnauthorized: false });
  assert.doesNotMatch(s.connectionString, /sslmode|supa=/);
  assert.match(s.connectionString, /:6543\/postgres$/);
  const l = connectionConfig('postgres://postgres@127.0.0.1:5432/x');
  assert.equal(l.ssl, undefined);
});

test('email content escapes the name and carries the link', () => {
  const m = downloadEmail({ name: '<b>Ada</b> L', link: 'https://x.app/api/download?t=a.b', days: 7 });
  assert.match(m.html, /Hi &lt;b&gt;Ada&lt;\/b&gt;,/);
  assert.match(m.html, /href="https:\/\/x\.app\/api\/download\?t=a\.b"/);
  assert.doesNotMatch(m.html, /suya/i);
  assert.match(m.text, /works for 7 days/);
});

test('sign-up is refused clearly when the site is not configured', async () => {
  const saved = { ...process.env };
  delete process.env.POSTGRES_URL; delete process.env.DATABASE_URL; delete process.env.SUPABASE_URL;
  process.env.LINK_SECRET = 'x';
  const { default: signup } = await import('../api/signup.js');
  const res = mockRes();
  await signup({ method: 'POST', headers: { host: 'x' }, body: { name: 'Ada', email: 'ada@example.com' } }, res);
  assert.equal(res.statusCode, 500);
  assert.match(res.body.error, /not set up yet/);
  process.env = saved;
});

const dbUrl = process.env.TEST_DATABASE_URL;
test('sign-up saves to Postgres and hands back a download link that works', { skip: !dbUrl && 'TEST_DATABASE_URL not set' }, async () => {
  execFileSync(process.execPath, ['scripts/migrate.js'], { env: { ...process.env, POSTGRES_URL_NON_POOLING: dbUrl }, stdio: 'pipe' });
  delete process.env.SUPABASE_URL;
  delete process.env.SUPABASE_SERVICE_ROLE_KEY;
  Object.assign(process.env, { POSTGRES_URL: dbUrl, LINK_SECRET: 'link-secret' });
  const db = await import('../lib/db.js');
  const { default: signup } = await import('../api/signup.js');
  const { default: download } = await import('../api/download.js');
  const pool = db.getPool();
  const email = `flow-${Date.now()}@example.com`;
  const post = async (body, headers = {}) => {
    const res = mockRes();
    await signup({ method: 'POST', headers: { host: 'x.vercel.app', ...headers }, body }, res);
    return res;
  };
  try {
    // validation; the honeypot gets no link
    assert.equal((await post({ name: 'Ada', email: 'nope' })).statusCode, 400);
    const bot = await post({ name: 'Bot', email: 'b@b.co', website: 'spam' });
    assert.equal(bot.statusCode, 200);
    assert.equal(bot.body.downloadUrl, undefined);

    // real sign-up returns a same-site signed link
    let res = await post(JSON.stringify({ name: ' Ada Lovelace ', email: email.toUpperCase(), updates: true }),
      { 'x-vercel-ip-country': 'NG', 'user-agent': 'UA' });
    assert.equal(res.statusCode, 200, JSON.stringify(res.body));
    assert.match(res.body.downloadUrl, /^\/api\/download\?t=[\w-]+\.[\w-]+$/);
    let row = (await pool.query('SELECT * FROM signups WHERE email = $1', [email])).rows[0];
    assert.equal(row.name, 'Ada Lovelace');
    assert.equal(row.country, 'NG');
    assert.equal(row.wants_updates, true);

    // the link redirects to the installer and logs the download
    res = mockRes();
    const link = (await post({ name: 'Ada', email })).body.downloadUrl;
    await download({ url: link, headers: { 'x-vercel-ip-country': 'NG' } }, res);
    assert.equal(res.statusCode, 302);
    assert.match(res.headers.location, /ScreenRecorder-Setup\.exe$/);
    const dl = (await pool.query('SELECT count(*)::int AS n FROM downloads WHERE email = $1', [email])).rows[0];
    assert.equal(dl.n, 1);
    row = (await pool.query('SELECT signup_count FROM signups WHERE email = $1', [email])).rows[0];
    assert.equal(row.signup_count, 2);

    // a tampered link shows the expired page
    res = mockRes();
    await download({ url: link + 'x', headers: {} }, res);
    assert.equal(res.statusCode, 410);
  } finally {
    await pool.query('DELETE FROM downloads WHERE email = $1', [email]);
    await pool.query('DELETE FROM signups WHERE email = $1', [email]);
    await db.closePool();
  }
});

test('download check says whether the APK is published', async () => {
  const { published } = await import('../api/download.js');
  const ok = await published('x.apk', async () => ({ status: 302 }), 1);
  const missing = await published('y.apk', async () => ({ status: 404 }), 1);
  assert.equal(ok, true);
  assert.equal(missing, false);
});
