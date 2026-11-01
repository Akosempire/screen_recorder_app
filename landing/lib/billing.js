// Pro plans sold through Bachs (https://bachs.io), and the licences they unlock.
//
// Flow
//  1. The app (or the website) makes a long random `activation` id and calls
//     POST /api/checkout with a plan and currency. We create a Bachs hosted
//     checkout and remember the activation.
//  2. The customer pays on Bachs. Bachs sends signed webhooks; only those grant
//     access (never the browser's return to the success page).
//  3. The app polls GET /api/license?activation=… until the licence is active,
//     then stores the licence key and checks it from time to time.
//
// Everything here takes its dependencies (`store`, `bachs`) as arguments so it
// can be tested without Supabase or real payments.
import { createHmac, randomBytes } from 'node:crypto';

export const APP_TAG = 'screen_recorder';

/** Prices. Bachs charges what's on the product; these create the products. */
export const PLANS = {
  monthly: {
    name: 'Screen Recorder Pro (monthly)',
    description: 'Unlimited recording length. Renews every month; cancel any time.',
    USD: '5.00',
    interval: 'month',
  },
  lifetime: {
    name: 'Screen Recorder Pro (lifetime)',
    description: 'Unlimited recording length, forever. One payment.',
    USD: '50.00',
    interval: null,
  },
};

/** Pro is sold in US dollars only. */
export const CURRENCIES = ['USD'];

/** Subscription states that keep Pro on (past_due: Bachs is retrying a renewal). */
const ACTIVE_STATES = new Set(['active', 'trialing', 'past_due']);

/** Grace after a monthly period ends before Pro switches off. */
const GRACE_MS = 3 * 24 * 3600 * 1000;

// ---- which currencies Bachs can actually charge --------------------------------
// Bachs refuses a checkout in a currency with no payment method switched on
// (BILLING_CURRENCY_HAS_NO_PAYMENT_METHOD). We remember that, so the website and
// app stop offering it; the dashboard test (or a later success) clears it.
const unavailableKey = (currency) => `currency_unavailable:${currency}`;
export const NO_METHOD = 'BILLING_CURRENCY_HAS_NO_PAYMENT_METHOD';

export async function availableCurrencies(store) {
  const out = [];
  for (const c of CURRENCIES) {
    const flag = await store.getSetting(unavailableKey(c)).catch(() => null);
    if (!flag) out.push(c);
  }
  return out.length ? out : ['USD'];
}

async function markCurrency(store, currency, ok) {
  try { await store.setSetting(unavailableKey(currency), ok ? '' : new Date().toISOString()); } catch { /* not critical */ }
}

/** One line saying what went wrong, for the admin log (never shown to buyers). */
export function describeError(error) {
  if (!error) return 'unknown error';
  const parts = [];
  if (error.stage) parts.push(`[${error.stage}]`);
  if (error.statusCode) parts.push(`Bachs ${error.statusCode}${error.errorCode ? ` ${error.errorCode}` : ''}:`);
  parts.push(String(error.message || error).replace(/(sk|whsec)_[A-Za-z0-9_]+/g, '$1_…'));
  if (Array.isArray(error.fieldErrors) && error.fieldErrors.length) {
    parts.push(JSON.stringify(error.fieldErrors).slice(0, 200));
  }
  return parts.join(' ').slice(0, 300);
}

/** Runs one step of a checkout, tagging any error with the step's name. */
async function step(stage, fn) {
  try {
    return await fn();
  } catch (error) {
    if (error && typeof error === 'object' && !error.stage) error.stage = stage;
    throw error;
  }
}

export class BillingError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export const isActivation = (value) => typeof value === 'string' && /^[A-Za-z0-9_-]{24,100}$/.test(value);
export const isLicenseKey = (value) => typeof value === 'string' && /^SR-[A-Z2-7]{4}(-[A-Z2-7]{4}){3}$/.test(value);

const BASE32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
function base32(bytes) {
  let bits = 0, value = 0, out = '';
  for (const b of bytes) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out += BASE32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  return out;
}

/**
 * The licence key for a checkout. Derived from the activation id with a
 * server secret, so retried or duplicate webhooks always produce the same key
 * (no duplicate licences) and nobody can guess a key.
 */
export function licenseKeyFor(activation, secret) {
  if (!secret) throw new BillingError(500, 'LICENSE_SECRET is not set.');
  const digest = createHmac('sha256', secret).update(`licence:${activation}`).digest();
  const s = base32(digest).slice(0, 16);
  return `SR-${s.slice(0, 4)}-${s.slice(4, 8)}-${s.slice(8, 12)}-${s.slice(12, 16)}`;
}

export const newActivation = () => randomBytes(24).toString('base64url');

// ---- products ---------------------------------------------------------------

/**
 * Bachs product ids for both plans: from env (BACHS_PRODUCT_MONTHLY /
 * BACHS_PRODUCT_LIFETIME), else remembered in app_settings, else found by
 * metadata on Bachs, else created there once.
 */
export async function productIds({ store, bachs, env = process.env }) {
  const mode = env.BACHS_ENVIRONMENT === 'production' ? 'production' : 'sandbox';
  const ids = { monthly: env.BACHS_PRODUCT_MONTHLY || null, lifetime: env.BACHS_PRODUCT_LIFETIME || null };
  if (ids.monthly && ids.lifetime) return ids;

  // Keyed by price: changing a price in PLANS makes (and then reuses) new products.
  const priceTag = Object.keys(PLANS).map((k) => `${k}-${PLANS[k].USD}`).join('_');
  const settingKey = `bachs_products_${mode}_${priceTag}`;
  const saved = await store.getSetting(settingKey);
  if (saved) {
    try {
      const parsed = JSON.parse(saved);
      ids.monthly ||= parsed.monthly;
      ids.lifetime ||= parsed.lifetime;
    } catch { /* ignore a bad value and rebuild */ }
  }

  if (!ids.monthly || !ids.lifetime) {
    // Look for products made earlier (e.g. if saving the setting failed).
    const existing = await listAll(bachs);
    for (const product of existing) {
      const meta = product.metadata || {};
      if (meta.app === APP_TAG && PLANS[meta.plan] && meta.usd === PLANS[meta.plan].USD && !product.archived_at && !ids[meta.plan]) {
        ids[meta.plan] = product.id;
      }
    }
  }

  for (const plan of Object.keys(PLANS)) {
    if (ids[plan]) continue;
    const p = PLANS[plan];
    const created = await bachs.products.create({
      name: p.name,
      description: p.description,
      price: { currency: 'USD', amount: p.USD },
      ...(p.interval ? { billing_cycle: { interval: p.interval, frequency: 1 } } : {}),
      metadata: { app: APP_TAG, plan, usd: p.USD },
    }, { idempotencyKey: `${APP_TAG}-product-${plan}-${mode}-${p.USD}` });
    ids[plan] = created.id;
  }

  await store.setSetting(settingKey, JSON.stringify(ids));
  return ids;
}

async function listAll(bachs) {
  const out = [];
  for await (const product of bachs.products.listAll({ limit: 100 })) {
    out.push(product);
    if (out.length >= 1000) break;
  }
  return out;
}

// ---- checkout -----------------------------------------------------------------

/**
 * The admin's "Test the Bachs connection": every step a real purchase takes,
 * without saving anything. Returns { ok, steps: [{ name, ok, detail }] }.
 */
export async function testCheckout({ store, bachs, env = process.env, email }) {
  const steps = [];
  const run = async (name, fn) => {
    try {
      const detail = await fn();
      steps.push({ name, ok: true, detail: detail || '' });
      return true;
    } catch (error) {
      steps.push({ name, ok: false, detail: describeError(error) });
      return false;
    }
  };
  const site = (env.SITE_URL || 'https://screenrecorderapp.vercel.app').replace(/\/+$/, '');
  let ids;
  const ok = await run('Bachs key works', async () => { await bachs.products.list({ limit: 1 }); return env.BACHS_ENVIRONMENT === 'production' ? 'live' : 'sandbox'; })
    && await run('Database tables ready', async () => { await store.getCheckout('x'.repeat(32)); return 'checkouts table found'; })
    && await run('Pro products on Bachs', async () => { ids = await productIds({ store, bachs, env }); return `monthly ${ids.monthly}, lifetime ${ids.lifetime}`; })
    && (await Promise.all(CURRENCIES.map((currency) => run(`Checkout page in ${currency}`, async () => {
      const session = await bachs.checkoutSessions.create({
        product_cart: [{ product_id: ids.monthly, quantity: 1 }],
        customer: { email, name: 'Dashboard test' },
        billing_currency: currency,
        metadata: { app: `${APP_TAG}-test` },
        success_url: `${site}/pro.html`,
        cancel_url: `${site}/#pricing`,
        expires_in_minutes: 5,
      });
      await markCurrency(store, currency, true);
      return session.checkout_url ? 'opens fine' : 'no checkout link returned';
    }).then(async (ok) => {
      if (!ok && steps.find((s) => s.name === `Checkout page in ${currency}`)?.detail.includes(NO_METHOD)) {
        await markCurrency(store, currency, false);
      }
      return ok;
    })))).every(Boolean);
  return { ok, steps };
}

/** Starts (or reuses) a hosted checkout. Returns { checkoutUrl, activation }. */
export async function startCheckout(input, { store, bachs, env = process.env }) {
  const plan = String(input.plan || '');
  const currency = String(input.currency || 'USD').toUpperCase();
  const email = String(input.email || '').trim().toLowerCase();
  const name = String(input.name || '').trim().slice(0, 80) || email.split('@')[0];
  const activation = String(input.activation || '');

  if (!PLANS[plan]) throw new BillingError(400, 'Choose Monthly or Lifetime.');
  if (!CURRENCIES.includes(currency)) throw new BillingError(400, 'Pro is paid in US dollars ($5 a month or $50 once). Please choose dollars, or update the app.');
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email) || email.length > 160) {
    throw new BillingError(400, 'Enter a valid email address, like you@example.com.');
  }
  if (!isActivation(activation)) throw new BillingError(400, 'Invalid request.');

  const existing = await step('database: read checkout', () => store.getCheckout(activation));
  if (existing?.license_key) throw new BillingError(409, 'This purchase is already complete.');
  if (existing?.checkout_url && existing.plan === plan && existing.currency === currency) {
    return { checkoutUrl: existing.checkout_url, activation };
  }

  const ids = await step('Bachs: products', () => productIds({ store, bachs, env }));
  const site = (env.SITE_URL || 'https://screenrecorderapp.vercel.app').replace(/\/+$/, '');
  await step('database: save checkout', () => store.saveCheckout({ activation, email, name, plan, currency }));

  let session;
  try {
    session = await step('Bachs: checkout session', () => bachs.checkoutSessions.create({
    product_cart: [{ product_id: ids[plan], quantity: 1 }],
    customer: { email, name },
    billing_currency: currency,
    metadata: { app: APP_TAG, activation, plan, email },
    reference: `sr-${plan}-${randomBytes(6).toString('hex')}`,
    success_url: `${site}/pro.html?a=${encodeURIComponent(activation)}`,
    cancel_url: `${site}/#pricing`,
  }, { idempotencyKey: `${APP_TAG}-checkout-${activation}-${plan}-${currency}` }));
  } catch (error) {
    if (error?.errorCode === NO_METHOD) {
      await markCurrency(store, currency, false);
      throw Object.assign(new BillingError(400, 'Payments aren\'t available right now. Please try again later.'), { stage: error.stage, cause: error });
    }
    throw error;
  }
  await markCurrency(store, currency, true);

  await step('database: save checkout link', () => store.saveCheckout({
    activation, email, name, plan, currency,
    bachs_checkout_id: session.checkout_id,
    checkout_url: session.checkout_url,
  }));
  return { checkoutUrl: session.checkout_url, activation };
}

// ---- webhooks -----------------------------------------------------------------

const meta = (data) => (data && typeof data.metadata === 'object' && data.metadata) || {};

/**
 * Applies one verified Bachs event. Safe to run more than once for the same
 * event: licences are keyed by activation. Returns what happened.
 */
export async function handleEvent(event, { store, env = process.env }) {
  if (!event?.id || !event?.type) throw new BillingError(400, 'Invalid event');
  if (await store.eventSeen(event.id)) return 'duplicate';

  const data = event.data || {};
  const m = meta(data);
  let result = 'ignored';

  if (m.app === APP_TAG && isActivation(m.activation)) {
    if (event.type === 'collection.succeeded') {
      const checkout = await store.getCheckout(m.activation);
      const plan = PLANS[m.plan] ? m.plan : checkout?.plan;
      if (plan) {
        const key = licenseKeyFor(m.activation, env.LICENSE_SECRET);
        if (store.recordPayment) {
          const amount = Number(data.settlement_amount ?? data.amount ?? data.amount_paid);
          await store.recordPayment({
            id: String(data.charge_id || data.payment_id || data.id || event.id),
            license_key: key,
            email: m.email || checkout?.email || null,
            plan,
            currency: data.settlement_currency || data.currency || checkout?.currency || null,
            amount: Number.isFinite(amount) ? amount : null,
            created_at: event.created_at,
          });
        }
        await grant({
          store, env, activation: m.activation, plan,
          email: m.email || checkout?.email, name: checkout?.name,
          currency: data.currency || checkout?.currency || null,
          status: 'active',
          // The first month counts from now; subscription events refine it.
          periodEnd: plan === 'monthly' ? new Date(Date.parse(event.created_at) + 31 * 24 * 3600 * 1000).toISOString() : null,
          checkoutId: data.checkout_id || checkout?.bachs_checkout_id || null,
          keepLaterPeriod: true,
        });
        result = 'granted';
      }
    } else if (event.type.startsWith('customer.subscription.')) {
      const checkout = await store.getCheckout(m.activation);
      const status = event.type === 'customer.subscription.deleted' ? 'canceled' : String(data.status || 'active');
      await grant({
        store, env, activation: m.activation, plan: 'monthly',
        email: m.email || checkout?.email, name: checkout?.name,
        currency: data.currency || checkout?.currency || null,
        status,
        periodEnd: typeof data.current_period_end === 'string' ? data.current_period_end : null,
        subscriptionId: data.subscription_id || data.id || null,
        customerId: data.customer?.customer_id || data.customer?.id || data.customer_id || null,
      });
      result = 'subscription';
    }
  }

  await store.markEvent(event.id, event.type);
  return result;
}

async function grant({ store, env, activation, plan, email, name, currency, status, periodEnd,
  subscriptionId, customerId, checkoutId, keepLaterPeriod = false }) {
  if (!email) throw new BillingError(500, 'Payment has no email');
  const key = licenseKeyFor(activation, env.LICENSE_SECRET);
  const existing = await store.getLicense(key);
  const fields = {
    license_key: key,
    email,
    plan,
    status,
    ...(name ? { name } : {}),
    ...(currency ? { currency } : {}),
    ...(subscriptionId ? { bachs_subscription_id: subscriptionId } : {}),
    ...(customerId ? { bachs_customer_id: customerId } : {}),
    ...(checkoutId ? { bachs_checkout_id: checkoutId } : {}),
  };
  if (periodEnd) {
    const later = existing?.current_period_end && Date.parse(existing.current_period_end) > Date.parse(periodEnd);
    if (!(keepLaterPeriod && later)) fields.current_period_end = periodEnd;
  }
  // An admin's revoke sticks; payments for a revoked licence don't revive it.
  if (existing?.status === 'revoked') {
    fields.status = 'revoked';
  } else if (existing?.plan === 'lifetime') {
    // A payment never downgrades a lifetime licence.
    fields.plan = 'lifetime';
    fields.status = 'active';
    delete fields.current_period_end;
  }
  await store.saveLicense(fields);
  await store.saveCheckout({ activation, license_key: key });
}

// ---- licence checks -----------------------------------------------------------

/** Whether a stored licence row unlocks Pro right now. */
export function isActive(license, now = Date.now()) {
  if (!license) return false;
  if (license.plan === 'lifetime') return license.status === 'active';
  if (!ACTIVE_STATES.has(license.status)) {
    // Cancelled subscriptions keep Pro until the paid period ends.
    if (license.status === 'canceled' && license.current_period_end) {
      return Date.parse(license.current_period_end) > now;
    }
    return false;
  }
  if (!license.current_period_end) return true;
  return Date.parse(license.current_period_end) + GRACE_MS > now;
}

/** What the app sees about a licence (no customer details beyond a masked email). */
export function publicLicense(license, now = Date.now()) {
  if (!license) return { active: false };
  const [user, domain] = String(license.email).split('@');
  return {
    active: isActive(license, now),
    key: license.license_key,
    plan: license.plan,
    status: license.status,
    renews: license.plan === 'monthly' && license.status !== 'canceled' ? license.current_period_end || null : null,
    endsAt: license.plan === 'monthly' && license.status === 'canceled' ? license.current_period_end || null : null,
    email: `${user.slice(0, 2)}${'•'.repeat(Math.max(1, user.length - 2))}@${domain}`,
    canManage: license.plan === 'monthly' && Boolean(license.bachs_customer_id),
  };
}

/** Licence by activation (for the app/website waiting after checkout). */
export async function claim(activation, { store }) {
  if (!isActivation(activation)) throw new BillingError(400, 'Invalid request.');
  const checkout = await store.getCheckout(activation);
  if (!checkout) throw new BillingError(404, 'Unknown purchase.');
  if (!checkout.license_key) return { pending: true, plan: checkout.plan };
  return { pending: false, ...publicLicense(await store.getLicense(checkout.license_key)) };
}

export async function check(key, { store }) {
  if (!isLicenseKey(key)) throw new BillingError(400, 'That doesn\'t look like a licence key (SR-XXXX-XXXX-XXXX-XXXX).');
  const license = await store.getLicense(key);
  if (!license) throw new BillingError(404, 'No licence with that key.');
  return publicLicense(license);
}

/** Bachs customer portal (manage or cancel a monthly plan). */
export async function portal(key, { store, bachs }) {
  if (!isLicenseKey(key)) throw new BillingError(400, 'Invalid licence key.');
  const license = await store.getLicense(key);
  if (!license?.bachs_customer_id) throw new BillingError(404, 'There is no subscription to manage for this licence.');
  const session = await bachs.customerPortal.createSession(license.bachs_customer_id);
  return { url: session.url };
}
