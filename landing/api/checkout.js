import { describeError, newActivation, startCheckout } from '../lib/billing.js';
import { logAction } from '../lib/admin.js';
import * as db from '../lib/supabase-rest.js';
import { bachsClient, currentConfig, paymentsConfigured, supabaseStore } from '../lib/billing-store.js';
import { readJson, sendError } from '../lib/http.js';

// POST /api/checkout { plan: monthly|lifetime, currency: USD, email, name, activation? }
// Returns { checkoutUrl, activation }. The app sends its own activation id so
// it can collect the licence afterwards; the website gets a new one.
export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'Use POST.' });
  }
  try {
    const config = await currentConfig();
    if (!paymentsConfigured(config)) return res.status(503).json({ error: 'Payments are not switched on yet. Try again soon.' });
    const body = await readJson(req);
    const result = await startCheckout(
      { ...body, activation: body.activation || newActivation() },
      { store: supabaseStore, bachs: bachsClient(config), env: config },
    );
    res.setHeader('Cache-Control', 'no-store');
    return res.status(200).json(result);
  } catch (error) {
    // Buyers get a plain message; the admin dashboard's Activity log gets the reason.
    if (!(Number.isInteger(error?.status) && error.status < 500)) {
      await logAction(db, 'website', 'checkout_failed', describeError(error));
    }
    return sendError(res, error, 'We couldn\'t start the payment. Try again in a minute.');
  }
}
