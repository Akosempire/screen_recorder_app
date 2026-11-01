import { PLANS } from '../lib/billing.js';
import { currentConfig, paymentsConfigured } from '../lib/billing-store.js';

// GET /api/plans: what the app and website need to know about Pro.
// `enabled` is false until payments are connected and switched on in the
// admin dashboard; the app only enforces the free limit (and the website only
// offers checkout) once payments work. Prices are in US dollars only.
export default async function handler(req, res) {
  const limit = Number(process.env.FREE_LIMIT_SECONDS || 180);
  let enabled = false;
  try {
    enabled = paymentsConfigured(await currentConfig());
  } catch { /* database unreachable: stay free */ }
  res.setHeader('Cache-Control', 'public, max-age=60');
  return res.status(200).json({
    enabled,
    currencies: ['USD'],
    currency: 'USD',
    freeLimitSeconds: Number.isFinite(limit) && limit > 0 ? limit : 180,
    plans: {
      monthly: { USD: PLANS.monthly.USD, interval: 'month' },
      lifetime: { USD: PLANS.lifetime.USD, interval: null },
    },
  });
}
