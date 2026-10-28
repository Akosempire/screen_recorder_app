import assert from 'node:assert/strict';
import test from 'node:test';
import { countryOf, currencyFor } from '../lib/geo.js';
import plans from '../api/plans.js';

const req = (country) => ({ url: '/api/plans', headers: country ? { 'x-vercel-ip-country': country } : {} });

test('visitors in Nigeria see naira, everyone else dollars', () => {
  assert.equal(currencyFor(countryOf(req('NG'))), 'NGN');
  assert.equal(currencyFor(countryOf(req('ng'))), 'NGN');
  assert.equal(currencyFor(countryOf(req('US'))), 'USD');
  assert.equal(currencyFor(countryOf(req('GH'))), 'USD');
  assert.equal(countryOf(req('XX')), null);
  assert.equal(countryOf(req('<script>')), null);
  assert.equal(currencyFor(countryOf(req())), 'USD');
});

test('/api/plans reports the country and is not shared between visitors', async () => {
  let status, body; const headers = {};
  const res = {
    setHeader: (k, v) => { headers[k.toLowerCase()] = v; },
    status(s) { status = s; return this; },
    json(b) { body = b; return this; },
  };
  await plans(req('NG'), res);
  assert.equal(status, 200);
  assert.equal(body.country, 'NG');
  assert.equal(body.currency, 'NGN');
  assert.match(headers['cache-control'], /private/);
  assert.equal(headers.vary, 'x-vercel-ip-country');
});
