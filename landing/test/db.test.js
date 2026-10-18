// Runs against a real Postgres when TEST_DATABASE_URL is set (a Neon dev branch or local Postgres):
//   TEST_DATABASE_URL=postgres://... npm test
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import pg from 'pg';

const url = process.env.TEST_DATABASE_URL;

test('signups and downloads persist in Postgres', { skip: !url && 'TEST_DATABASE_URL not set' }, async () => {
  execFileSync(process.execPath, ['scripts/migrate.js'], {
    env: { ...process.env, DATABASE_URL: url, DATABASE_URL_UNPOOLED: url },
    stdio: 'pipe',
  });
  process.env.DATABASE_URL = url;
  const db = await import('../lib/db.js');
  const email = `test-${Date.now()}@example.com`;
  try {
    const first = await db.saveSignup({ name: 'Ada', email, updates: true, country: 'NG', userAgent: 'node' });
    assert.equal(first.signup_count, 1);
    const again = await db.saveSignup({ name: 'Ada L', email, updates: false });
    assert.equal(again.id, first.id);
    assert.equal(again.signup_count, 2);
    assert.equal(again.name, 'Ada L');
    await db.logDownload({ email, country: 'NG' });
    const { rows } = await db.getPool().query('SELECT count(*)::int AS n FROM downloads WHERE email = $1', [email]);
    assert.equal(rows[0].n, 1);
  } finally {
    const c = new pg.Client({ connectionString: url });
    await c.connect();
    await c.query('DELETE FROM downloads WHERE email = $1', [email]);
    await c.query('DELETE FROM signups WHERE email = $1', [email]);
    await c.end();
    await db.closePool();
  }
});
