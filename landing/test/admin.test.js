import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { makeSession, readSession } from '../lib/admin-auth.js';
import { toCsv } from '../lib/admin.js';
import { decrypt, encrypt, loadConfig, paymentsOn, publicSettings } from '../lib/config.js';

const ENV = { LINK_SECRET: 'link-secret-for-tests' };

test('settings secrets are encrypted and tamper-proof', () => {
  const stored = encrypt('sk_sandbox_abcdef123456', ENV);
  assert.ok(!stored.includes('sk_sandbox'), 'plaintext never stored');
  assert.equal(decrypt(stored, ENV), 'sk_sandbox_abcdef123456');
  assert.throws(() => decrypt(stored, { LINK_SECRET: 'another-secret' }));
  const [v, iv, tag, data] = stored.split('.');
  assert.throws(() => decrypt([v, iv, tag, data.slice(0, -2) + 'AA'].join('.'), ENV));
});

test('config: dashboard values win, licence secret is created once, payments switch', async () => {
  const settings = {};
  const store = { getSetting: async (k) => settings[k] ?? null, setSetting: async (k, v) => { settings[k] = v; } };
  const env = { ...ENV, BACHS_API_KEY: 'sk_sandbox_fromvercel1' };
  let c = await loadConfig(store, env);
  assert.equal(c.BACHS_API_KEY, 'sk_sandbox_fromvercel1');
  assert.ok(c.LICENSE_SECRET.length > 30);
  const secret = c.LICENSE_SECRET;
  assert.equal((await loadConfig(store, env)).LICENSE_SECRET, secret, 'stable');
  assert.equal(paymentsOn(c), false, 'no webhook secret yet');

  settings['cfg:bachs_api_key'] = encrypt('sk_sandbox_fromdashboard', env);
  settings['cfg:bachs_webhook_secret'] = encrypt('whsec_fromdashboard1', env);
  c = await loadConfig(store, env);
  assert.equal(c.BACHS_API_KEY, 'sk_sandbox_fromdashboard');
  assert.equal(paymentsOn(c), true);
  settings['cfg:payments_enabled'] = 'off';
  assert.equal(paymentsOn(await loadConfig(store, env)), false);

  const pub = publicSettings(c);
  assert.ok(!JSON.stringify(pub).includes('fromdashboard'), 'secrets are masked');
  assert.match(pub.bachs_api_key, /^sk_sandbox_…/);
});

test('admin sessions: signed, expiring, and only for listed admins', () => {
  const now = Date.now();
  const token = makeSession('boss@example.com', ENV, now);
  assert.equal(readSession(token, ['boss@example.com'], ENV, now + 1000), 'boss@example.com');
  assert.equal(readSession(token, ['someone@else.com'], ENV, now), null, 'removed from admins');
  assert.equal(readSession(token, ['boss@example.com'], ENV, now + 13 * 3600 * 1000), null, 'expired');
  assert.equal(readSession(token, ['boss@example.com'], { LINK_SECRET: 'x' }, now), null, 'wrong key');
  const [payload, sig] = token.split('.');
  const forged = Buffer.from(JSON.stringify({ e: 'boss@example.com', x: now + 1e12 })).toString('base64url');
  assert.equal(readSession(`${forged}.${sig}`, ['boss@example.com'], ENV, now), null, 'edited payload');
  assert.equal(readSession(`${payload}.`, ['boss@example.com'], ENV, now), null);
  assert.equal(readSession('garbage', ['boss@example.com'], ENV, now), null);
});

test('CSV export neutralises spreadsheet formulas', () => {
  const csv = toCsv([{ email: '=HYPERLINK("http://evil")', name: 'Ada, "A"' }]);
  assert.equal(csv, `email,name\n"'=HYPERLINK(""http://evil"")","Ada, ""A"""\n`);
});

// ---- the endpoint, against a fake Supabase (database + auth) ----------------

async function fakeSupabase(key, goodCode) {
  const tables = { licenses: [], checkouts: [], webhook_events: [], app_settings: [], admin_log: [], payments: [], signups: [], downloads: [] };
  const unique = { licenses: 'license_key', checkouts: 'activation', webhook_events: 'id', app_settings: 'key', payments: 'id' };
  const sent = [];
  let seq = 0;
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      const send = (status, body) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(body === undefined ? '' : JSON.stringify(body)); };
      if (req.headers.apikey !== key) return send(401, { message: 'bad key' });
      const url = new URL(req.url, 'http://x');
      const body = raw ? JSON.parse(raw) : null;
      if (url.pathname === '/auth/v1/otp') { sent.push(body.email); return send(200, {}); }
      if (url.pathname === '/auth/v1/verify') return body.token === goodCode ? send(200, { access_token: 't' }) : send(403, { msg: 'Token has expired or is invalid' });
      const rows = tables[url.pathname.replace('/rest/v1/', '')];
      if (!rows) return send(404, { message: 'no table' });
      const name = url.pathname.replace('/rest/v1/', '');
      const tests = [...url.searchParams].filter(([k]) => !['select', 'order', 'limit', 'on_conflict'].includes(k)).map(([k, v]) => {
        const [op, ...rest] = v.split('.');
        const val = rest.join('.');
        if (op === 'eq') return (r) => String(r[k]) === val;
        if (op === 'gte') return (r) => String(r[k]) >= val;
        if (op === 'ilike') { const needle = val.replace(/\*/g, '').toLowerCase(); return (r) => String(r[k] || '').toLowerCase().includes(needle); }
        return () => true;
      });
      const match = (r) => tests.every((t) => t(r));
      if (req.method === 'GET') return send(200, rows.filter(match));
      if (req.method === 'POST') {
        const u = unique[name];
        const found = u && rows.find((r) => r[u] === body[u]);
        if (found) {
          if ((req.headers.prefer || '').includes('merge-duplicates')) { Object.assign(found, body); return send(201, [found]); }
          return send(409, { code: '23505', message: 'duplicate' });
        }
        const row = { id: ++seq, created_at: new Date().toISOString(), ...body };
        rows.push(row); return send(201, [row]);
      }
      if (req.method === 'PATCH') { const hit = rows.filter(match); hit.forEach((r) => Object.assign(r, body)); return send(200, hit); }
      return send(405, {});
    });
  });
  await new Promise((r) => server.listen(0, r));
  return { tables, sent, url: `http://127.0.0.1:${server.address().port}`, close: () => server.close() };
}

function call(handler, { method = 'GET', action, body, cookie, query = '', json = true }) {
  return new Promise((resolve) => {
    const res = { statusCode: 200, headers: {} };
    res.status = (c) => { res.statusCode = c; return res; };
    res.json = (b) => { res.body = b; resolve(res); return res; };
    res.send = (b) => { res.body = b; resolve(res); return res; };
    res.setHeader = (k, v) => { res.headers[k.toLowerCase()] = v; };
    res.end = (b) => { res.body = b; resolve(res); return res; };
    handler({
      method, url: `/api/admin?action=${action}${query}`, body,
      headers: { ...(json && method === 'POST' ? { 'content-type': 'application/json' } : {}), ...(cookie ? { cookie } : {}) },
    }, res);
  });
}

test('admin endpoint: sign in by email code, lockout, settings, licences, CSV', async () => {
  const key = 'service-role';
  const sb = await fakeSupabase(key, '123456');
  Object.assign(process.env, { SUPABASE_URL: sb.url, SUPABASE_SERVICE_ROLE_KEY: key, LINK_SECRET: ENV.LINK_SECRET, ADMIN_EMAILS: 'boss@example.com' });
  delete process.env.BACHS_API_KEY;
  const { default: admin } = await import('../api/admin.js');
  const { default: license } = await import('../api/license.js');
  try {
    // Not signed in.
    assert.equal((await call(admin, { action: 'overview' })).statusCode, 401);

    // Strangers get the same answer but no email.
    let r = await call(admin, { method: 'POST', action: 'login', body: { email: 'stranger@example.com' } });
    assert.equal(r.statusCode, 200);
    assert.deepEqual(sb.sent, []);
    r = await call(admin, { method: 'POST', action: 'login', body: { email: 'Boss@Example.com' } });
    assert.deepEqual(sb.sent, ['boss@example.com']);

    // Forms from other sites can't post (no JSON).
    assert.equal((await call(admin, { method: 'POST', action: 'verify', body: { email: 'boss@example.com', code: '123456' }, json: false })).statusCode, 415);

    // Wrong codes, then the right one sets a secure cookie.
    r = await call(admin, { method: 'POST', action: 'verify', body: { email: 'boss@example.com', code: '000000' } });
    assert.equal(r.statusCode, 401);
    r = await call(admin, { method: 'POST', action: 'verify', body: { email: 'boss@example.com', code: '123456' } });
    assert.equal(r.statusCode, 200);
    const setCookie = r.headers['set-cookie'];
    assert.match(setCookie, /^__Host-sr_admin=.+; Path=\/; HttpOnly; Secure; SameSite=Strict/);
    const cookie = setCookie.split(';')[0];

    r = await call(admin, { action: 'overview', cookie });
    assert.equal(r.statusCode, 200);
    assert.equal(r.body.settings.payments_live, false);

    // Settings: bad key rejected; good keys stored encrypted; selling switches on.
    r = await call(admin, { method: 'POST', action: 'settings', cookie, body: { bachs_api_key: 'not-a-key' } });
    assert.equal(r.statusCode, 400);
    r = await call(admin, { method: 'POST', action: 'settings', cookie, body: {
      bachs_api_key: 'sk_sandbox_realkey12345', bachs_webhook_secret: 'whsec_realsecret123', bachs_environment: 'sandbox', payments_enabled: true,
    } });
    assert.equal(r.statusCode, 200, JSON.stringify(r.body));
    assert.equal(r.body.payments_live, true);
    const storedKey = sb.tables.app_settings.find((s) => s.key === 'cfg:bachs_api_key').value;
    assert.ok(!storedKey.includes('realkey'), 'API key is encrypted in the database');

    // Give a licence, check it, revoke it, check again.
    r = await call(admin, { method: 'POST', action: 'grant', cookie, body: { email: 'friend@example.com', plan: 'lifetime', note: 'Thanks' } });
    assert.equal(r.statusCode, 200);
    const given = r.body.license_key;
    const check = () => new Promise((resolve) => {
      const res = { statusCode: 200, headers: {}, setHeader() {}, status(c) { this.statusCode = c; return this; }, json(b) { this.body = b; resolve(this); return this; } };
      license({ method: 'GET', url: `/api/license?key=${given}`, headers: {} }, res);
    });
    assert.equal((await check()).body.active, true);
    r = await call(admin, { method: 'POST', action: 'revoke', cookie, body: { key: given } });
    assert.equal(r.body.status, 'revoked');
    assert.equal((await check()).body.active, false);
    r = await call(admin, { method: 'POST', action: 'restore', cookie, body: { key: given } });
    assert.equal((await check()).body.active, true);

    r = await call(admin, { action: 'licenses', cookie, query: '&q=friend' });
    assert.equal(r.body.items.length, 1);

    // Downloads CSV.
    sb.tables.downloads.push({ id: 1, email: 'x@example.com', os: 'android', country: 'NG', created_at: new Date().toISOString() });
    r = await call(admin, { action: 'downloads', cookie, query: '&format=csv' });
    assert.match(r.headers['content-type'], /text\/csv/);
    assert.match(r.body, /x@example\.com,android,NG/);

    // Everything is logged.
    const actions = sb.tables.admin_log.map((l) => l.action);
    for (const a of ['login_failed', 'login', 'settings', 'grant', 'revoke', 'restore']) assert.ok(actions.includes(a), a);

    // Five wrong codes lock sign-in for 15 minutes.
    for (let i = 0; i < 4; i++) await call(admin, { method: 'POST', action: 'verify', body: { email: 'boss@example.com', code: '999999' } });
    r = await call(admin, { method: 'POST', action: 'verify', body: { email: 'boss@example.com', code: '123456' } });
    assert.equal(r.statusCode, 429);

    // A removed admin's cookie stops working.
    await call(admin, { method: 'POST', action: 'settings', cookie, body: { admin_emails: 'new@example.com' } });
    assert.equal((await call(admin, { action: 'overview', cookie })).statusCode, 401);
  } finally {
    sb.close();
  }
});

test('sign-in code errors say what to fix', async () => {
  const { codeError } = await import('../lib/admin-auth.js');
  assert.match(codeError(500, 'Error sending magic link email').message, /SMTP Settings/);
  assert.match(codeError(429, 'email rate limit exceeded').message, /Wait a few minutes/);
  assert.match(codeError(422, 'Signups not allowed for otp').message, /Allow new users to sign up/);
  assert.match(codeError(401, 'Invalid API key').message, /SUPABASE_SERVICE_ROLE_KEY/);
  assert.equal(codeError(500, 'x').status, 400);
});

test('team-only email error is explained, with Supabase\'s words', async () => {
  const { codeError } = await import('../lib/admin-auth.js');
  const e = codeError(400, 'Email address "a@b.com" cannot be used as it is not authorized');
  assert.match(e.message, /Organization → Team/);
  assert.match(e.message, /Supabase said: Email address/);
});
