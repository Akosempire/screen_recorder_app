import { PLANS } from '../lib/billing.js';
import { currentConfig, paymentsConfigured } from '../lib/billing-store.js';
import { countryOf, currencyFor } from '../lib/geo.js';

// GET /api/plans: what the app and website need to know about Pro.
// `enabled` is false until payments are connected and switched on in the
// admin dashboard; the app only enforces the free limit (and the website only
// offers checkout) once payments work. `currency` is NGN for visitors in
// Nigeria and USD elsewhere, from the visitor's IP country.
export default async function handler(req, res) {
  const limit = Number(process.env.FREE_LIMIT_SECONDS || 180);
  let enabled = false;
  try {
    enabled = paymentsConfigured(await currentConfig());
  } catch { /* database unreachable: stay free */ }
  const country = countryOf(req);
  // Per-visitor answer (country), so browsers may cache it but shared caches may not.
  res.setHeader('Cache-Control', 'private, max-age=60');
  res.setHeader('Vary', 'x-vercel-ip-country');
  return res.status(200).json({
    enabled,
    country,
    currency: currencyFor(country),
    freeLimitSeconds: Number.isFinite(limit) && limit > 0 ? limit : 180,
    plans: {
      monthly: { NGN: PLANS.monthly.NGN, USD: PLANS.monthly.USD, interval: 'month' },
      lifetime: { NGN: PLANS.lifetime.NGN, USD: PLANS.lifetime.USD, interval: null },
    },
  });
}
