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

// Fake SendByte API: records requests; `reply` decides the response.
async function fakeSendByte() {
  const sent = [];
  let reply = () => [201, { id: `em_${sent.length}`, status: 'queued', sandbox: false }];
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      const body = JSON.parse(raw || '{}');
      sent.push({ path: req.url, auth: req.headers.authorization, body });
      const [status, data] = reply(body);
      res.writeHead(status, { 'Content-Type': 'application/json', 'x-request-id': 'req_test' });
      res.end(JSON.stringify(data));
    });
  });
  await new Promise((r) => server.listen(0, r));
  return {
    sent,
    setReply: (fn) => { reply = fn; },
    url: `http://127.0.0.1:${server.address().port}/v1`,
    close: () => server.close(),
  };
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

test('email content escapes the name and carries the link and suya note', () => {
  const m = downloadEmail({ name: '<b>Ada</b> L', link: 'https://x.app/api/download?t=a.b', days: 7 });
  assert.match(m.html, /Hi &lt;b&gt;Ada&lt;\/b&gt;,/);
  assert.match(m.html, /href="https:\/\/x\.app\/api\/download\?t=a\.b"/);
  assert.match(m.html, /Buy me suya to keep it running/);
  assert.match(m.text, /works for 7 days/);
});

test('sign-up is refused clearly when the site is not configured', async () => {
  const saved = { ...process.env };
  delete process.env.POSTGRES_URL; delete process.env.DATABASE_URL; delete process.env.SENDBYTE_API_KEY;
  process.env.LINK_SECRET = 'x';
  const { default: signup } = await import('../api/signup.js');
  const res = mockRes();
  await signup({ method: 'POST', headers: { host: 'x' }, body: { name: 'Ada', email: 'ada@example.com' } }, res);
  assert.equal(res.statusCode, 500);
  assert.match(res.body.error, /not set up yet/);
  process.env = saved;
});

const dbUrl = process.env.TEST_DATABASE_URL;
test('sign-up saves to Postgres, emails via SendByte, and the link downloads', { skip: !dbUrl && 'TEST_DATABASE_URL not set' }, async () => {
  execFileSync(process.execPath, ['scripts/migrate.js'], { env: { ...process.env, POSTGRES_URL_NON_POOLING: dbUrl }, stdio: 'pipe' });
  const fake = await fakeSendByte();
  Object.assign(process.env, {
    POSTGRES_URL: dbUrl, LINK_SECRET: 'link-secret', SENDBYTE_API_URL: fake.url,
    SENDBYTE_API_KEY: 'sk_live_test', EMAIL_FROM: 'Screen Recorder <downloads@example.ng>',
  });
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
    // validation and honeypot send nothing
    assert.equal((await post({ name: 'Ada', email: 'nope' })).statusCode, 400);
    assert.equal((await post({ name: 'Bot', email: 'b@b.co', website: 'spam' })).statusCode, 200);
    assert.equal(fake.sent.length, 0);

    // real sign-up
    let res = await post(JSON.stringify({ name: ' Ada Lovelace ', email: email.toUpperCase(), updates: true }),
      { 'x-forwarded-proto': 'https', 'x-vercel-ip-country': 'NG', 'user-agent': 'UA' });
    assert.equal(res.statusCode, 200, JSON.stringify(res.body));
    const call = fake.sent[0];
    assert.equal(call.path, '/v1/emails');
    assert.equal(call.auth, 'Bearer sk_live_test');
    assert.deepEqual(call.body.to, [email]);
    assert.equal(call.body.from, 'Screen Recorder <downloads@example.ng>');
    assert.match(call.body.idempotency_key, /^dl-[0-9a-f]{32}$/);
    const link = call.body.text.match(/https:\/\/x\.vercel\.app\/api\/download\?t=\S+/)[0];
    let row = (await pool.query('SELECT * FROM signups WHERE email = $1', [email])).rows[0];
    assert.equal(row.name, 'Ada Lovelace');
    assert.equal(row.country, 'NG');
    assert.equal(row.wants_updates, true);
    assert.equal(row.last_email_id, 'em_1');

    // the emailed link redirects to the installer and logs the download
    res = mockRes();
    await download({ url: link.replace('https://x.vercel.app', ''), headers: { 'x-vercel-ip-country': 'NG' } }, res);
    assert.equal(res.statusCode, 302);
    assert.match(res.headers.location, /ScreenRecorder-Setup\.exe$/);
    const dl = (await pool.query('SELECT count(*)::int AS n FROM downloads WHERE email = $1', [email])).rows[0];
    assert.equal(dl.n, 1);

    // a tampered link shows the expired page
    res = mockRes();
    await download({ url: link.replace('https://x.vercel.app', '') + 'x', headers: {} }, res);
    assert.equal(res.statusCode, 410);

    // double click in the same minute: SendByte reports a key conflict; we treat it as sent
    fake.setReply(() => [409, { error: { code: 'idempotency_conflict', message: 'reused' } }]);
    assert.equal((await post({ name: 'Ada', email })).statusCode, 200);
    row = (await pool.query('SELECT signup_count FROM signups WHERE email = $1', [email])).rows[0];
    assert.equal(row.signup_count, 2);

    // unverified domain -> friendly 502, sign-up still saved
    fake.setReply(() => [403, { error: { code: 'domain_not_verified', message: 'verify your domain' } }]);
    res = await post({ name: 'Ada', email });
    assert.equal(res.statusCode, 502);
    assert.match(res.body.error, /could not be sent/);

    // suppressed recipient -> ask for another address
    fake.setReply(() => [422, { error: { code: 'suppressed_recipient', message: 'bounced' } }]);
    res = await post({ name: 'Ada', email });
    assert.equal(res.statusCode, 400);
    assert.match(res.body.error, /different one/);
  } finally {
    await pool.query('DELETE FROM downloads WHERE email = $1', [email]);
    await pool.query('DELETE FROM signups WHERE email = $1', [email]);
    await db.closePool();
    fake.close();
  }
});
