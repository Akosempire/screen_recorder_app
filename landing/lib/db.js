import pg from 'pg';
import { attachDatabasePool } from '@vercel/functions';
import * as rest from './supabase-rest.js';

// Two ways to reach the database:
//  1. Supabase's HTTPS API (SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY). Preferred:
//     no database password or connection pooler involved.
//  2. A Postgres connection string (POSTGRES_URL, or DATABASE_URL for local Postgres),
//     used when the Supabase API settings are not present.
let pool;

export function databaseUrl() {
  return process.env.POSTGRES_URL || process.env.DATABASE_URL || '';
}

export function hasDatabase() {
  return rest.configured() || Boolean(databaseUrl());
}

/**
 * Supabase serves TLS with its own certificate authority, which Node does not
 * trust by default, and newer `pg` treats `sslmode=require` as full
 * verification. For Supabase hosts we keep the connection encrypted but skip
 * CA verification; local Postgres connects as configured.
 */
export function connectionConfig(url = databaseUrl()) {
  let u;
  try {
    u = new URL(url);
  } catch {
    throw new Error(
      'POSTGRES_URL must be a full connection string like ' +
      'postgresql://postgres.<project>:<password>@aws-0-<region>.pooler.supabase.com:6543/postgres ' +
      `(it starts with "${String(url).slice(0, 12)}…").`,
    );
  }
  if (/\.supabase\.(co|com)$/.test(u.hostname)) {
    for (const key of ['sslmode', 'sslrootcert', 'sslcert', 'sslkey', 'supa']) u.searchParams.delete(key);
    return { connectionString: u.toString(), ssl: { rejectUnauthorized: false } };
  }
  return { connectionString: url };
}

export function getPool() {
  if (!pool) {
    if (!hasDatabase()) throw new Error('POSTGRES_URL is not set.');
    pool = new pg.Pool({
      ...connectionConfig(),
      max: 5,
      idleTimeoutMillis: 5000,
      connectionTimeoutMillis: 10000,
    });
    // Idle connections get closed by the server; without this the error would crash the function.
    pool.on('error', (error) => console.error('idle database client closed', error.message));
    attachDatabasePool(pool);
  }
  return pool;
}

/** Inserts or refreshes a sign-up. Returns the stored row. */
export async function saveSignup({ name, email, updates, country, userAgent }) {
  if (rest.configured()) return rest.saveSignup({ name, email, updates, country, userAgent });
  const { rows } = await getPool().query(
    `INSERT INTO signups (email, name, wants_updates, country, user_agent)
     VALUES ($1, $2, $3, $4, $5)
     ON CONFLICT (email) DO UPDATE SET
       name = EXCLUDED.name,
       wants_updates = EXCLUDED.wants_updates,
       country = EXCLUDED.country,
       user_agent = EXCLUDED.user_agent,
       signup_count = signups.signup_count + 1,
       updated_at = now()
     RETURNING id, email, name, wants_updates, signup_count`,
    [email, name, Boolean(updates), country || null, userAgent || null],
  );
  return rows[0];
}

export async function markEmailSent(email, messageId) {
  if (rest.configured()) return rest.markEmailSent(email, messageId);
  await getPool().query(
    'UPDATE signups SET last_email_id = $2, last_emailed_at = now() WHERE email = $1',
    [email, messageId || null],
  );
}

export async function logDownload({ email, country, userAgent, os }) {
  if (rest.configured()) return rest.logDownload({ email, country, userAgent, os });
  await getPool().query(
    'INSERT INTO downloads (email, country, user_agent) VALUES ($1, $2, $3)',
    [email, country || null, userAgent || null],
  );
}

/** Row counts for the health check (no personal data). */
export async function counts() {
  if (rest.configured()) return rest.counts();
  const { rows } = await getPool().query(
    `SELECT (SELECT count(*) FROM signups)::int AS signups,
            (SELECT count(*) FROM downloads)::int AS downloads`,
  );
  return rows[0];
}

export async function closePool() {
  if (pool) {
    const p = pool;
    pool = undefined;
    await p.end();
  }
}
