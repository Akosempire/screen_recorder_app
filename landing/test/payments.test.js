import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createHmac } from 'node:crypto';
import {
  PLANS, claim, check, handleEvent, isActive, isLicenseKey, licenseKeyFor, newActivation, productIds, startCheckout,
} from '../lib/billing.js';

const ENV = { LICENSE_SECRET: 'licence-secret', BACHS_ENVIRONMENT: 'sandbox', SITE_URL: 'https://example.app' };

function memoryStore() {
  const s = { settings: {}, checkouts: {}, licenses: {}, events: {} };
  return {
    s,
    async getSetting(k) { return s.settings[k] ?? null; },
    async setSetting(k, v) { s.settings[k] = v; },
    async getCheckout(a) { return s.checkouts[a] ?? null; },
    async saveCheckout(f) {
      if (s.checkouts[f.activation]) Object.assign(s.checkouts[f.activation], f);
      else if (f.email) s.checkouts[f.activation] = { ...f };
    },
    async getLicense(k) { return s.licenses[k] ?? null; },
    async saveLicense(f) { s.licenses[f.license_key] = { ...(s.licenses[f.license_key] || {}), ...f }; },
    async eventSeen(id) { return Boolean(s.events[id]); },
    async markEvent(id, type) { s.events[id] = type; },
  };
}

function fakeBachs({ existing = [] } = {}) {
  const calls = { created: [], sessions: [] };
  let n = 0;
  return {
    calls,
    products: {
      async *listAll() { yield* existing; },
      async create(input, opts) { calls.created.push({ input, opts }); return { id: `prod_${++n}` }; },
    },
    checkoutSessions: {
      async create(input, opts) {
        calls.sessions.push({ input, opts });
        return { checkout_id: `chk_${calls.sessions.length}`, checkout_url: `https://sandbox-checkout.bachs.io/c/${calls.sessions.length}` };
      },
    },
    customerPortal: { async createSession(id) { return { id: 'ps_1', url: `https://portal.example/${id}` }; } },
  };
}

const event = (type, data, extra = {}) => ({
  id: `evt_${Math.random().toString(36).slice(2)}`, type, created_at: new Date().toISOString(),
  organization_id: 'org_1', data, ...extra,
});

test('prices: ₦2,000 / $5 monthly and ₦50,000 / $100 lifetime', () => {
  assert.equal(PLANS.monthly.NGN, '2000.00');
  assert.equal(PLANS.monthly.USD, '5.00');
  assert.equal(PLANS.lifetime.NGN, '50000.00');
  assert.equal(PLANS.lifetime.USD, '100.00');
});

test('products are created once with naira prices, then reused', async () => {
  const store = memoryStore();
  const bachs = fakeBachs();
  const ids = await productIds({ store, bachs, env: ENV });
  assert.deepEqual(Object.keys(ids).sort(), ['lifetime', 'monthly']);
  assert.equal(bachs.calls.created.length, 2);
  const monthly = bachs.calls.created.find((c) => c.input.metadata.plan === 'monthly').input;
  assert.deepEqual(monthly.billing_cycle, { interval: 'month', frequency: 1 });
  assert.deepEqual(monthly.price, { currency: 'USD', amount: '5.00', currency_options: [{ currency: 'NGN', amount: '2000.00' }] });
  const lifetime = bachs.calls.created.find((c) => c.input.metadata.plan === 'lifetime').input;
  assert.equal(lifetime.billing_cycle, undefined);
  assert.equal(lifetime.price.currency_options[0].amount, '50000.00');

  await productIds({ store, bachs, env: ENV });
  assert.equal(bachs.calls.created.length, 2, 'second call reuses the saved ids');

  // Products already on Bachs (e.g. the setting was lost) are found, not duplicated.
  const found = fakeBachs({ existing: [
    { id: 'prod_m', metadata: { app: 'screen_recorder', plan: 'monthly' } },
    { id: 'prod_l', metadata: { app: 'screen_recorder', plan: 'lifetime' } },
  ] });
  assert.deepEqual(await productIds({ store: memoryStore(), bachs: found, env: ENV }), { monthly: 'prod_m', lifetime: 'prod_l' });
  assert.equal(found.calls.created.length, 0);
});

test('checkout: validates input, sends metadata and currency, reuses an open checkout', async () => {
  const store = memoryStore();
  const bachs = fakeBachs();
  const activation = newActivation();
  const deps = { store, bachs, env: ENV };
  await assert.rejects(startCheckout({ plan: 'weekly', currency: 'NGN', email: 'a@b.co', activation }, deps), /Monthly or Lifetime/);
  await assert.rejects(startCheckout({ plan: 'monthly', currency: 'EUR', email: 'a@b.co', activation }, deps), /naira/);
  await assert.rejects(startCheckout({ plan: 'monthly', currency: 'NGN', email: 'nope', activation }, deps), /valid email/);
  await assert.rejects(startCheckout({ plan: 'monthly', currency: 'NGN', email: 'a@b.co', activation: 'short' }, deps), /Invalid/);

  const out = await startCheckout({ plan: 'lifetime', currency: 'NGN', email: 'Ada@Example.com', name: 'Ada', activation }, deps);
  assert.match(out.checkoutUrl, /^https:\/\/sandbox-checkout\.bachs\.io\//);
  const sent = bachs.calls.sessions[0].input;
  assert.equal(sent.billing_currency, 'NGN');
  assert.deepEqual(sent.metadata, { app: 'screen_recorder', activation, plan: 'lifetime', email: 'ada@example.com' });
  assert.deepEqual(sent.customer, { email: 'ada@example.com', name: 'Ada' });
  assert.equal(sent.success_url, `https://example.app/pro.html?a=${activation}`);
  assert.equal(store.s.checkouts[activation].checkout_url, out.checkoutUrl);

  const again = await startCheckout({ plan: 'lifetime', currency: 'NGN', email: 'ada@example.com', activation }, deps);
  assert.equal(again.checkoutUrl, out.checkoutUrl);
  assert.equal(bachs.calls.sessions.length, 1);
});

test('lifetime: a paid checkout becomes a licence the app can collect and check', async () => {
  const store = memoryStore();
  const deps = { store, bachs: fakeBachs(), env: ENV };
  const activation = newActivation();
  await startCheckout({ plan: 'lifetime', currency: 'USD', email: 'ada@example.com', name: 'Ada', activation }, deps);
  assert.deepEqual(await claim(activation, deps), { pending: true, plan: 'lifetime' });

  // Somebody else's app's event, and unrelated events, change nothing.
  assert.equal(await handleEvent(event('collection.succeeded', { metadata: { app: 'other' } }), { store, env: ENV }), 'ignored');

  const paid = event('collection.succeeded', { checkout_id: 'chk_1', currency: 'USD', metadata: { app: 'screen_recorder', activation, plan: 'lifetime', email: 'ada@example.com' } });
  assert.equal(await handleEvent(paid, { store, env: ENV }), 'granted');
  assert.equal(await handleEvent(paid, { store, env: ENV }), 'duplicate');

  const got = await claim(activation, deps);
  assert.equal(got.pending, false);
  assert.equal(got.active, true);
  assert.equal(got.plan, 'lifetime');
  assert.ok(isLicenseKey(got.key), got.key);
  assert.equal(got.key, licenseKeyFor(activation, ENV.LICENSE_SECRET));
  assert.equal(got.email, 'ad•@example.com');
  assert.equal((await check(got.key, deps)).active, true);
  await assert.rejects(check('SR-AAAA-AAAA-AAAA-AAAA', deps), /No licence/);
  await assert.rejects(check('hello', deps), /doesn't look like/);
});

test('monthly: first payment, renewal, cancellation keeps Pro until the period ends', async () => {
  const store = memoryStore();
  const deps = { store, bachs: fakeBachs(), env: ENV };
  const activation = newActivation();
  await startCheckout({ plan: 'monthly', currency: 'NGN', email: 'bo@example.com', activation }, deps);
  const m = { app: 'screen_recorder', activation, plan: 'monthly', email: 'bo@example.com' };

  await handleEvent(event('collection.succeeded', { currency: 'NGN', metadata: m }), { store, env: ENV });
  const key = licenseKeyFor(activation, ENV.LICENSE_SECRET);
  assert.equal(isActive(store.s.licenses[key]), true);

  const in20Days = new Date(Date.now() + 20 * 864e5).toISOString();
  await handleEvent(event('customer.subscription.created', {
    subscription_id: 'sub_1', status: 'active', current_period_end: in20Days,
    customer: { customer_id: 'cus_1' }, metadata: m,
  }), { store, env: ENV });
  const lic = store.s.licenses[key];
  assert.equal(lic.bachs_subscription_id, 'sub_1');
  assert.equal(lic.bachs_customer_id, 'cus_1');
  assert.equal(lic.current_period_end, in20Days);
  assert.equal((await check(key, deps)).canManage, true);

  await handleEvent(event('customer.subscription.deleted', {
    subscription_id: 'sub_1', status: 'canceled', current_period_end: in20Days, metadata: m,
  }), { store, env: ENV });
  assert.equal(store.s.licenses[key].status, 'canceled');
  assert.equal(isActive(store.s.licenses[key]), true, 'paid month still runs');
  assert.equal(isActive(store.s.licenses[key], Date.now() + 21 * 864e5), false, 'and then ends');

  // A failed renewal (past_due) keeps Pro during Bachs's retries, for a few days.
  store.s.licenses[key].status = 'past_due';
  store.s.licenses[key].current_period_end = new Date(Date.now() - 864e5).toISOString();
  assert.equal(isActive(store.s.licenses[key]), true);
  store.s.licenses[key].current_period_end = new Date(Date.now() - 4 * 864e5).toISOString();
  assert.equal(isActive(store.s.licenses[key]), false);
});

test('a subscription event never downgrades a lifetime licence', async () => {
  const store = memoryStore();
  const deps = { store, bachs: fakeBachs(), env: ENV };
  const activation = newActivation();
  await startCheckout({ plan: 'lifetime', currency: 'NGN', email: 'c@example.com', activation }, deps);
  const m = { app: 'screen_recorder', activation, plan: 'lifetime', email: 'c@example.com' };
  await handleEvent(event('collection.succeeded', { metadata: m }), { store, env: ENV });
  await handleEvent(event('customer.subscription.deleted', { status: 'canceled', metadata: m }), { store, env: ENV });
  const lic = store.s.licenses[licenseKeyFor(activation, ENV.LICENSE_SECRET)];
  assert.equal(lic.plan, 'lifetime');
  assert.equal(lic.status, 'active');
});

// ---- the real endpoints, against a fake Supabase ----------------------------

async function fakePostgrest(key) {
  const tables = { licenses: [], checkouts: [], webhook_events: [], app_settings: [] };
  const unique = { licenses: 'license_key', checkouts: 'activation', webhook_events: 'id', app_settings: 'key' };
  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      const send = (status, body) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(body === undefined ? '' : JSON.stringify(body)); };
      if (req.headers.apikey !== key) return send(401, { message: 'bad key' });
      const url = new URL(req.url, 'http://x');
      const name = url.pathname.replace('/rest/v1/', '');
      const rows = tables[name];
      if (!rows) return send(404, { message: 'no table' });
      const filters = [...url.searchParams].filter(([k, v]) => v.startsWith('eq.')).map(([k, v]) => [k, decodeURIComponent(v.slice(3))]);
      const match = (r) => filters.every(([k, v]) => String(r[k]) === v);
      const body = raw ? JSON.parse(raw) : null;
      if (req.method === 'GET') return send(200, rows.filter(match));
      if (req.method === 'POST') {
        const u = unique[name];
        const found = rows.find((r) => r[u] === body[u]);
        if (found) {
          if ((req.headers.prefer || '').includes('merge-duplicates')) { Object.assign(found, body); return send(201, [found]); }
          return send(409, { code: '23505', message: 'duplicate' });
        }
        rows.push({ ...body }); return send(201, [body]);
      }
      if (req.method === 'PATCH') { const hit = rows.filter(match); hit.forEach((r) => Object.assign(r, body)); return send(200, hit); }
      return send(405, {});
    });
  });
  await new Promise((r) => server.listen(0, r));
  return { tables, url: `http://127.0.0.1:${server.address().port}`, close: () => server.close() };
}

function mockRes() {
  const res = { statusCode: 200, headers: {}, body: undefined };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; return res; };
  res.send = (b) => { res.body = b; return res; };
  res.setHeader = (k, v) => { res.headers[k.toLowerCase()] = v; };
  res.end = (b) => { res.body = b; return res; };
  return res;
}

function signedRequest(bodyObj, secret, { tamper = false } = {}) {
  const raw = Buffer.from(JSON.stringify(bodyObj));
  const t = Math.floor(Date.now() / 1000);
  const sig = createHmac('sha256', secret).update(`${t}.`).update(raw).digest('hex');
  const sent = tamper ? Buffer.from(JSON.stringify({ ...bodyObj, id: 'evt_forged' })) : raw;
  return {
    method: 'POST',
    headers: { 'x-bachs-signature-v2': `t=${t},v1=${sig}`, 'content-type': 'application/json' },
    async *[Symbol.asyncIterator]() { yield sent; },
  };
}

test('webhook endpoint verifies signatures and grants the licence; licence endpoint reports it', async () => {
  const key = 'service-role';
  const sb = await fakePostgrest(key);
  Object.assign(process.env, {
    SUPABASE_URL: sb.url, SUPABASE_SERVICE_ROLE_KEY: key,
    BACHS_WEBHOOK_SECRET: 'whsec_test', LICENSE_SECRET: ENV.LICENSE_SECRET, BACHS_API_KEY: 'sk_sandbox_test',
  });
  const { default: webhook } = await import('../api/bachs-webhook.js');
  const { default: license } = await import('../api/license.js');
  try {
    const activation = newActivation();
    sb.tables.checkouts.push({ activation, email: 'dee@example.com', name: 'Dee', plan: 'lifetime', currency: 'NGN' });
    const evt = event('collection.succeeded', { currency: 'NGN', metadata: { app: 'screen_recorder', activation, plan: 'lifetime', email: 'dee@example.com' } });

    let res = mockRes();
    await webhook(signedRequest(evt, 'whsec_wrong'), res);
    assert.equal(res.statusCode, 400, 'wrong secret');
    res = mockRes();
    await webhook(signedRequest(evt, 'whsec_test', { tamper: true }), res);
    assert.equal(res.statusCode, 400, 'tampered body');
    assert.equal(sb.tables.licenses.length, 0);

    res = mockRes();
    await webhook(signedRequest(evt, 'whsec_test'), res);
    assert.equal(res.statusCode, 200, String(res.body));
    assert.equal(sb.tables.licenses.length, 1);
    assert.equal(sb.tables.webhook_events.length, 1);

    res = mockRes();
    await license({ method: 'GET', url: `/api/license?activation=${activation}`, headers: {} }, res);
    assert.equal(res.statusCode, 200);
    assert.equal(res.body.active, true);
    const licenceKey = res.body.key;

    res = mockRes();
    await license({ method: 'GET', url: `/api/license?key=${licenceKey.toLowerCase()}`, headers: {} }, res);
    assert.equal(res.body.plan, 'lifetime');
    assert.equal(res.body.active, true);

    res = mockRes();
    await license({ method: 'POST', url: '/api/license', headers: {}, body: { action: 'portal', key: licenceKey } }, res);
    assert.equal(res.statusCode, 404, 'lifetime has no subscription to manage');
  } finally {
    sb.close();
  }
});
