// Pro, the same as in the desktop app: $5 a month or $50 once removes the
// 3-minute limit. Uses the website's API; the licence is kept in
// chrome.storage.local and re-checked now and then (monthly licences keep
// working offline for 14 days after the last check).
export const API = 'https://screenrecorderapp.vercel.app';
export const PRICES = { monthly: '$5 a month', lifetime: '$50 once' };

const OFFLINE_DAYS = 14;
const get = (keys) => chrome.storage.local.get(keys);
const set = (obj) => chrome.storage.local.set(obj);

async function api(path, { method = 'GET', body, fetcher = fetch } = {}) {
  const res = await fetcher(`${API}${path}`, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw Object.assign(new Error(data.error || 'Could not reach Screen Recorder. Check your connection.'), { status: res.status });
  return data;
}

/** { enabled, freeLimitSeconds } — cached so it works offline. */
export async function plans({ refresh = false } = {}) {
  const { plans: cached, plansAt } = await get(['plans', 'plansAt']);
  if (cached && !refresh && Date.now() - (plansAt || 0) < 3600_000) return cached;
  try {
    const p = await api('/api/plans');
    const value = { enabled: p.enabled === true, freeLimitSeconds: Number(p.freeLimitSeconds) > 0 ? Number(p.freeLimitSeconds) : 180 };
    await set({ plans: value, plansAt: Date.now() });
    return value;
  } catch {
    return cached || { enabled: false, freeLimitSeconds: 180 };
  }
}

export async function license() {
  const { license: l, licenseCheckedAt } = await get(['license', 'licenseCheckedAt']);
  return l ? { ...l, checkedAt: licenseCheckedAt || 0 } : null;
}

export function isPro(l, now = Date.now()) {
  if (!l || !l.active) return false;
  if (l.plan === 'lifetime') return true;
  return now - (l.checkedAt || 0) < OFFLINE_DAYS * 86400_000;
}

/** Seconds a recording may last right now, or 0 for no limit. */
export async function recordingLimit() {
  const [p, l] = await Promise.all([plans(), refreshLicense()]);
  return p.enabled && !isPro(l) ? p.freeLimitSeconds : 0;
}

/** Re-checks the saved licence at most every 6 hours. */
export async function refreshLicense({ force = false } = {}) {
  const l = await license();
  if (!l?.key) return l;
  if (!force && Date.now() - (l.checkedAt || 0) < 6 * 3600_000) return l;
  try {
    const fresh = await api(`/api/license?key=${encodeURIComponent(l.key)}`);
    await set({ license: fresh, licenseCheckedAt: Date.now() });
    return { ...fresh, checkedAt: Date.now() };
  } catch (error) {
    if (error.status === 404) {
      await chrome.storage.local.remove(['license', 'licenseCheckedAt']);
      return null;
    }
    return l; // offline: keep what we had
  }
}

export async function activateKey(key) {
  const k = String(key || '').trim().toUpperCase();
  const fresh = await api(`/api/license?key=${encodeURIComponent(k)}`);
  if (!fresh.active) throw new Error('This licence is not active (it may have ended or been cancelled).');
  await set({ license: fresh, licenseCheckedAt: Date.now() });
  return fresh;
}

export async function removeLicense() {
  await chrome.storage.local.remove(['license', 'licenseCheckedAt', 'pendingActivation']);
}

function newActivation() {
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Starts checkout; returns the payment page URL. */
export async function buy({ plan, name, email }) {
  const activation = newActivation();
  const r = await api('/api/checkout', { method: 'POST', body: { plan, currency: 'USD', name, email, activation } });
  await set({ pendingActivation: { activation, plan, at: Date.now() } });
  return r.checkoutUrl;
}

/** Checks a purchase in progress. Returns the licence once paid, else null. */
export async function checkPayment() {
  const { pendingActivation: p } = await get(['pendingActivation']);
  if (!p) return null;
  const r = await api(`/api/license?activation=${encodeURIComponent(p.activation)}`);
  if (r.pending) return null;
  await set({ license: r, licenseCheckedAt: Date.now() });
  await chrome.storage.local.remove('pendingActivation');
  return r;
}

export async function manageUrl() {
  const l = await license();
  if (!l?.key) throw new Error('No licence saved.');
  return (await api('/api/license', { method: 'POST', body: { action: 'portal', key: l.key } })).url;
}
