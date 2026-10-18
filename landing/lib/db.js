import pg from 'pg';
import { attachDatabasePool } from '@vercel/functions';

// One pool per function instance, on Neon's pooled DATABASE_URL.
// attachDatabasePool lets Vercel Fluid compute close idle clients before the
// instance is suspended, so connections are not leaked.
let pool;

export function hasDatabase() {
  return Boolean(process.env.DATABASE_URL);
}

export function getPool() {
  if (!pool) {
    if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL is not set.');
    pool = new pg.Pool({
      connectionString: process.env.DATABASE_URL,
      max: 5,
      idleTimeoutMillis: 5000,
      connectionTimeoutMillis: 10000,
    });
    // Idle connections get closed by the server (e.g. Neon scaling to zero).
    // Without this handler that error would crash the function.
    pool.on('error', (error) => console.error('idle database client closed', error.message));
    attachDatabasePool(pool);
  }
  return pool;
}

/** Inserts or refreshes a sign-up. Returns the stored row. */
export async function saveSignup({ name, email, updates, country, userAgent }) {
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

export async function logDownload({ email, country, userAgent }) {
  await getPool().query(
    'INSERT INTO downloads (email, country, user_agent) VALUES ($1, $2, $3)',
    [email, country || null, userAgent || null],
  );
}

export async function closePool() {
  if (pool) {
    const p = pool;
    pool = undefined;
    await p.end();
  }
}
