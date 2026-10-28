import { check, claim, portal } from '../lib/billing.js';
import { bachsClient, currentConfig, supabaseStore } from '../lib/billing-store.js';
import { configured } from '../lib/supabase-rest.js';
import { readJson, sendError } from '../lib/http.js';

// GET  /api/license?key=SR-…            → licence status (the app checks this)
// GET  /api/license?activation=…        → status of a purchase in progress
// POST /api/license { action: "portal", key }  → link to manage the subscription
export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  // Licence checks keep working when new payments are switched off.
  if (!configured()) return res.status(503).json({ error: 'Payments are not switched on yet.' });
  try {
    const url = new URL(req.url, 'http://local');
    if (req.method === 'GET') {
      const activation = url.searchParams.get('activation');
      if (activation) return res.status(200).json(await claim(activation, { store: supabaseStore }));
      const key = (url.searchParams.get('key') || '').trim().toUpperCase();
      return res.status(200).json(await check(key, { store: supabaseStore }));
    }
    if (req.method === 'POST') {
      const body = await readJson(req);
      if (body.action === 'portal') {
        const key = String(body.key || '').trim().toUpperCase();
        return res.status(200).json(await portal(key, { store: supabaseStore, bachs: bachsClient(await currentConfig()) }));
      }
      return res.status(400).json({ error: 'Unknown action.' });
    }
    res.setHeader('Allow', 'GET, POST');
    return res.status(405).json({ error: 'Use GET or POST.' });
  } catch (error) {
    return sendError(res, error, 'Could not check the licence. Try again in a minute.');
  }
}
