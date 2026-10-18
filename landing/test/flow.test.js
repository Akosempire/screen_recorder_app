import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { makeToken, readToken } from '../lib/token.js';

// Minimal stand-ins for Vercel's req/res.
function mockRes() {
  const res = { statusCode: 200, headers: {}, body: undefined };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  res.setHeader = (k, v) => { res.headers[k.toLowerCase()] = v; };
  res.end = (b) => { res.body = b; return res; };
  return res;
}

// Fake Apps Script: records events, answers like the real one.
async function fakeAppsScript() {
  const events = [];
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      const body = JSON.parse(raw);
      res.setHeader('Content-Type', 'application/json');
      if (body.secret !== 'sheet-secret') return res.end(JSON.stringify({ ok: false, error: 'Not allowed.' }));
      events.push(body);
      res.end(JSON.stringify({ ok: true }));
    });
  });
  await new Promise((r) => server.listen(0, r));
  return { events, url: `http://127.0.0.1:${server.address().port}/exec`, close: () => server.close() };
}

test('token round-trip, tamper and expiry', () => {
  const t = makeToken('a@b.co', 's1', 1000);
  assert.equal(readToken(t, 's1', 2000), 'a@b.co');
  assert.equal(readToken(t, 'other', 2000), null);
  assert.equal(readToken(t.slice(0, -2) + 'xx', 's1', 2000), null);
  assert.equal(readToken(t, 's1', 1000 + 8 * 864e5), null);
  assert.equal(readToken('garbage', 's1'), null);
});

test('sign-up saves to the sheet and the emailed link downloads', async () => {
  const fake = await fakeAppsScript();
  process.env.APPS_SCRIPT_URL = fake.url;
  process.env.APPS_SCRIPT_SECRET = 'sheet-secret';
  process.env.LINK_SECRET = 'link-secret';
  const { default: signup } = await import('../api/signup.js');
  const { default: download } = await import('../api/download.js');

  // validation
  let res = mockRes();
  await signup({ method: 'POST', headers: { host: 'x.vercel.app' }, body: { name: 'Ada', email: 'nope' } }, res);
  assert.equal(res.statusCode, 400);
  assert.match(res.body.error, /valid email/);

  // honeypot: pretends success, saves nothing
  res = mockRes();
  await signup({ method: 'POST', headers: { host: 'x.vercel.app' }, body: { name: 'Bot', email: 'b@b.co', website: 'spam' } }, res);
  assert.equal(res.statusCode, 200);
  assert.equal(fake.events.length, 0);

  // real sign-up
  res = mockRes();
  await signup({
    method: 'POST',
    headers: { host: 'x.vercel.app', 'x-forwarded-proto': 'https', 'x-vercel-ip-country': 'NG', 'user-agent': 'UA' },
    body: JSON.stringify({ name: ' Ada Lovelace ', email: 'Ada@Example.com', updates: true }),
  }, res);
  assert.equal(res.statusCode, 200, JSON.stringify(res.body));
  const ev = fake.events[0];
  assert.equal(ev.action, 'signup');
  assert.equal(ev.name, 'Ada Lovelace');
  assert.equal(ev.email, 'ada@example.com');
  assert.equal(ev.updates, true);
  assert.equal(ev.country, 'NG');
  assert.match(ev.link, /^https:\/\/x\.vercel\.app\/api\/download\?t=/);

  // the emailed link redirects to the installer and logs the download
  res = mockRes();
  await download({ url: ev.link.replace('https://x.vercel.app', ''), headers: {} }, res);
  assert.equal(res.statusCode, 302);
  assert.match(res.headers.location, /ScreenRecorder-Setup\.exe$/);
  assert.equal(fake.events[1].action, 'download');
  assert.equal(fake.events[1].email, 'ada@example.com');

  // a tampered link shows the expired page
  res = mockRes();
  await download({ url: ev.link.replace('https://x.vercel.app', '') + 'x', headers: {} }, res);
  assert.equal(res.statusCode, 410);
  assert.match(res.body, /expired/);

  // sheet rejects (wrong secret) -> friendly 502
  process.env.APPS_SCRIPT_SECRET = 'wrong';
  res = mockRes();
  await signup({ method: 'POST', headers: { host: 'x.vercel.app' }, body: { name: 'Ada', email: 'ada@example.com' } }, res);
  assert.equal(res.statusCode, 502);
  assert.match(res.body.error, /could not be sent/);
  fake.close();
});
