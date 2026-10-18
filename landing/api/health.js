import { counts, hasDatabase } from '../lib/db.js';

// GET /api/health -> { ok, database: { connected, signups, downloads } }
// Shows only counts, never personal data.
export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (!hasDatabase()) {
    return res.status(503).json({ ok: false, database: { connected: false, error: 'Database settings are not set.' } });
  }
  try {
    return res.status(200).json({ ok: true, database: { connected: true, ...(await counts()) } });
  } catch (error) {
    console.error('health check failed', error);
    return res.status(503).json({ ok: false, database: { connected: false, error: 'Database unreachable.' } });
  }
}
