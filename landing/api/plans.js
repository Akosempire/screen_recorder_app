import { PLANS } from '../lib/billing.js';
import { paymentsConfigured } from '../lib/billing-store.js';

// GET /api/plans: what the app and website need to know about Pro.
// `enabled` is false until Bachs is connected; the app only enforces the free
// limit (and the website only offers checkout) once payments work.
export default function handler(req, res) {
  const limit = Number(process.env.FREE_LIMIT_SECONDS || 180);
  res.setHeader('Cache-Control', 'public, max-age=300');
  return res.status(200).json({
    enabled: paymentsConfigured(),
    freeLimitSeconds: Number.isFinite(limit) && limit > 0 ? limit : 180,
    plans: {
      monthly: { NGN: PLANS.monthly.NGN, USD: PLANS.monthly.USD, interval: 'month' },
      lifetime: { NGN: PLANS.lifetime.NGN, USD: PLANS.lifetime.USD, interval: null },
    },
  });
}
