import { getPool, hasDatabase } from '../lib/db.js';

// GET /api/health -> { ok, database: { connected, signups, downloads } }
// Shows only counts, never personal data.
export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (!hasDatabase()) {
    return res.status(503).json({ ok: false, database: { connected: false, error: 'DATABASE_URL is not set.' } });
  }
  try {
    const { rows } = await getPool().query(
      `SELECT (SELECT count(*) FROM signups)::int AS signups,
              (SELECT count(*) FROM downloads)::int AS downloads`,
    );
    return res.status(200).json({ ok: true, database: { connected: true, ...rows[0] } });
  } catch (error) {
    console.error('health check failed', error);
    return res.status(503).json({ ok: false, database: { connected: false, error: 'Database unreachable.' } });
  }
}
