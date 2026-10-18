import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';

// A tiny stand-in for Supabase's REST API (PostgREST) covering what the site uses.
async function fakeSupabase(key) {
  const signups = [];
  const downloads = [];
  const requests = [];
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      const url = new URL(req.url, 'http://x');
      requests.push({ method: req.method, path: url.pathname, auth: req.headers.authorization, apikey: req.headers.apikey });
      const send = (status, body, headers = {}) => {
        res.writeHead(status, { 'Content-Type': 'application/json', ...headers });
        res.end(body === undefined ? '' : JSON.stringify(body));
      };
      if (req.headers.apikey !== key || req.headers.authorization !== `Bearer ${key}`) {
        return send(401, { message: 'Invalid API key' });
      }
      const table = url.pathname.replace('/rest/v1/', '');
      const rows = table === 'signups' ? signups : table === 'downloads' ? downloads : null;
      if (!rows) return send(404, { code: 'PGRST205', message: 'table not found' });
      const emailEq = url.searchParams.get('email')?.replace(/^eq\./, '');
      const body = raw ? JSON.parse(raw) : null;
      const wantsRows = (req.headers.prefer || '').includes('return=representation');

      if (req.method === 'POST') {
        if (table === 'signups' && rows.some((r) => r.email === body.email)) {
          return send(409, { code: '23505', message: 'duplicate key value violates unique constraint "signups_email_key"' });
        }
        const row = { id: rows.length + 1, signup_count: 1, ...body };
        rows.push(row);
        return wantsRows ? send(201, [row]) : send(201);
      }
      if (req.method === 'PATCH') {
        const hit = rows.filter((r) => r.email === emailEq);
        hit.forEach((r) => Object.assign(r, body));
        return wantsRows ? send(200, hit) : send(204);
      }
      if (req.method === 'GET') {
        const hit = emailEq ? rows.filter((r) => r.email === emailEq) : rows;
        return send(200, hit.slice(0, Number(url.searchParams.get('limit') || 1000)), {
          'Content-Range': `0-${Math.max(0, hit.length - 1)}/${hit.length}`,
        });
      }
      return send(405, { message: 'method' });
    });
  });
  await new Promise((r) => server.listen(0, r));
  return { signups, downloads, requests, url: `http://127.0.0.1:${server.address().port}`, close: () => server.close() };
}

function mockRes() {
  const res = { statusCode: 200, headers: {}, body: undefined };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  res.setHeader = (k, v) => { res.headers[k.toLowerCase()] = v; };
  res.end = (b) => { res.body = b; return res; };
  return res;
}

test('Supabase API: sign-up, repeat sign-up, download link and health counts', async () => {
  const key = 'service-role-test-key';
  const sb = await fakeSupabase(key);
  delete process.env.POSTGRES_URL;
  delete process.env.DATABASE_URL;
  Object.assign(process.env, {
    SUPABASE_URL: sb.url + '/',
    SUPABASE_SERVICE_ROLE_KEY: key,
    LINK_SECRET: 'link-secret',
  });
  const { default: signup } = await import('../api/signup.js');
  const { default: download } = await import('../api/download.js');
  const { default: health } = await import('../api/health.js');
  try {
    const post = async (body) => {
      const res = mockRes();
      await signup({ method: 'POST', headers: { host: 'x.vercel.app', 'x-vercel-ip-country': 'NG' }, body }, res);
      return res;
    };

    let res = await post({ name: 'Ada', email: 'Ada@Example.com', updates: true });
    assert.equal(res.statusCode, 200, JSON.stringify(res.body));
    assert.deepEqual(
      { ...sb.signups[0], updated_at: undefined, last_emailed_at: undefined },
      {
        id: 1, signup_count: 1, email: 'ada@example.com', name: 'Ada', wants_updates: true,
        country: 'NG', user_agent: null, updated_at: undefined, last_emailed_at: undefined,
      },
    );
    assert.ok(sb.requests.every((r) => r.apikey === key && r.auth === `Bearer ${key}`));

    // same person again: one row, counted twice, details refreshed
    res = await post({ name: 'Ada Lovelace', email: 'ada@example.com' });
    assert.equal(res.statusCode, 200);
    assert.equal(sb.signups.length, 1);
    assert.equal(sb.signups[0].signup_count, 2);
    assert.equal(sb.signups[0].name, 'Ada Lovelace');
    assert.equal(sb.signups[0].wants_updates, false);
    assert.match(res.body.downloadUrl, /^\/api\/download\?t=/);

    // the returned link downloads and is logged
    const link = res.body.downloadUrl;
    res = mockRes();
    await download({ url: link, headers: {} }, res);
    assert.equal(res.statusCode, 302);
    assert.equal(sb.downloads.length, 1);
    assert.equal(sb.downloads[0].email, 'ada@example.com');

    res = mockRes();
    await health({}, res);
    assert.deepEqual(res.body, { ok: true, database: { connected: true, signups: 1, downloads: 1 } });

    // a wrong key is reported as unreachable, and sign-up says it could not save
    process.env.SUPABASE_SERVICE_ROLE_KEY = 'wrong';
    res = mockRes();
    await health({}, res);
    assert.equal(res.statusCode, 503);
    res = await post({ name: 'Bo', email: 'bo@example.com' });
    assert.equal(res.statusCode, 502);
    assert.match(res.body.error, /could not save/);
  } finally {
    sb.close();
  }
});

test('Supabase Auth sends the magic link that redirects to the signed download link', async () => {
  const calls = [];
  let status = 200;
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      calls.push({ method: req.method, url: req.url, apikey: req.headers.apikey, body: raw ? JSON.parse(raw) : null });
      res.writeHead(status, { 'Content-Type': 'application/json' });
      res.end(status === 200 ? '{}' : JSON.stringify({ code: 429, error_code: 'over_email_send_rate_limit', msg: 'email rate limit exceeded' }));
    });
  });
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  delete process.env.EMAIL_PROVIDER;
  delete process.env.SENDBYTE_API_KEY;
  Object.assign(process.env, { SUPABASE_URL: base, SUPABASE_SERVICE_ROLE_KEY: 'svc', LINK_SECRET: 'link-secret' });
  const email = await import('../lib/email.js');
  try {
    assert.equal(email.emailProvider(), 'supabase');
    assert.equal(email.hasEmail(), true);
    const link = 'https://x.vercel.app/api/download?t=abc.def';
    const id = await email.sendDownloadEmail({ name: 'Ada', email: 'ada@example.com', link, days: 7 });
    assert.equal(id, null);
    const c = calls[0];
    assert.equal(c.method, 'POST');
    assert.equal(c.apikey, 'svc');
    const url = new URL(c.url, base);
    assert.equal(url.pathname, '/auth/v1/otp');
    assert.equal(url.searchParams.get('redirect_to'), link);
    assert.deepEqual(c.body, { email: 'ada@example.com', create_user: true, data: { name: 'Ada', source: 'download' } });

    // Supabase's email limit surfaces as a friendly 429 from the sign-up endpoint
    status = 429;
    await assert.rejects(email.sendDownloadEmail({ name: 'Ada', email: 'ada@example.com', link, days: 7 }), (e) => e.code === 'rate_limited');

    // EMAIL_PROVIDER=sendbyte switches back (and needs SendByte settings)
    process.env.EMAIL_PROVIDER = 'sendbyte';
    assert.equal(email.emailProvider(), 'sendbyte');
    assert.equal(email.hasEmail(), false);
  } finally {
    server.close();
  }
});
