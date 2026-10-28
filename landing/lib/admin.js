// Admin dashboard data and actions. Every function takes the database helpers
// (`db`) so it can be tested without Supabase.
import { BillingError, isActive, isLicenseKey, licenseKeyFor, newActivation } from './billing.js';

const day = 24 * 3600 * 1000;
const like = (q) => `*${String(q).replace(/[*,()]/g, ' ').trim()}*`;

export async function overview(db, now = Date.now()) {
  const [licenses, payments, signups, downloads] = await Promise.all([
    db.select('licenses', 'order=created_at.desc&limit=5000', 'license_key,email,plan,status,current_period_end,created_at,note'),
    db.select('payments', 'order=created_at.desc&limit=5000', 'id,email,plan,currency,amount,created_at').catch(() => []),
    db.select('signups', 'order=created_at.desc&limit=5000', 'id,created_at').catch(() => []),
    db.select('downloads', 'order=created_at.desc&limit=5000', 'id,os,country,created_at').catch(() => []),
  ]);
  const active = licenses.filter((l) => isActive(l, now));
  const since = (rows, days) => rows.filter((r) => Date.parse(r.created_at) > now - days * day).length;
  const revenue = {};
  const revenue30 = {};
  for (const p of payments) {
    if (!p.currency || p.amount === null || p.amount === undefined) continue;
    const amt = Number(p.amount);
    revenue[p.currency] = (revenue[p.currency] || 0) + amt;
    if (Date.parse(p.created_at) > now - 30 * day) revenue30[p.currency] = (revenue30[p.currency] || 0) + amt;
  }
  const byOs = {};
  for (const d of downloads) byOs[d.os || 'windows'] = (byOs[d.os || 'windows'] || 0) + 1;
  return {
    pro: {
      active: active.length,
      lifetime: active.filter((l) => l.plan === 'lifetime').length,
      monthly: active.filter((l) => l.plan === 'monthly').length,
      total: licenses.length,
    },
    revenue,
    revenue30,
    sales: payments.length,
    sales30: since(payments, 30),
    signups: signups.length,
    signups7: since(signups, 7),
    downloads: downloads.length,
    downloads7: since(downloads, 7),
    downloadsByOs: byOs,
    recentPayments: payments.slice(0, 10),
  };
}

export async function listLicenses(db, q = '') {
  const query = String(q || '').trim();
  let filter = 'order=created_at.desc&limit=200';
  if (query) {
    filter += isLicenseKey(query.toUpperCase())
      ? `&license_key=eq.${encodeURIComponent(query.toUpperCase())}`
      : `&email=ilike.${encodeURIComponent(like(query))}`;
  }
  const rows = await db.select('licenses', filter);
  return rows.map((l) => ({ ...l, active: isActive(l) }));
}

/** Gives someone Pro without payment. */
export async function grantLicense(db, { email, plan, months, note }, config, now = Date.now()) {
  const address = String(email || '').trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(address)) throw new BillingError(400, 'Enter a valid email address.');
  if (!['monthly', 'lifetime'].includes(plan)) throw new BillingError(400, 'Choose monthly or lifetime.');
  const m = Math.min(Math.max(parseInt(months, 10) || 1, 1), 36);
  const key = licenseKeyFor(newActivation(), config.LICENSE_SECRET);
  const row = {
    license_key: key,
    email: address,
    plan,
    status: 'active',
    current_period_end: plan === 'monthly' ? new Date(now + m * 30 * day).toISOString() : null,
    note: String(note || '').trim().slice(0, 200) || 'Given from the admin dashboard',
  };
  await db.insert('licenses', row);
  return row;
}

export async function setRevoked(db, key, revoked) {
  if (!isLicenseKey(key)) throw new BillingError(400, 'Invalid licence key.');
  const rows = await db.update('licenses', db.eq('license_key', key), revoked
    ? { status: 'revoked', revoked_at: new Date().toISOString() }
    : { status: 'active', revoked_at: null });
  if (!rows.length) throw new BillingError(404, 'No licence with that key.');
  return rows[0];
}

export async function listPeople(db, table, q = '') {
  if (!['downloads', 'signups'].includes(table)) throw new BillingError(400, 'Unknown list.');
  let filter = 'order=created_at.desc&limit=1000';
  const query = String(q || '').trim();
  if (query) filter += `&email=ilike.${encodeURIComponent(like(query))}`;
  return db.select(table, filter);
}

export function toCsv(rows) {
  if (!rows.length) return '';
  const cols = Object.keys(rows[0]);
  const cell = (v) => {
    const s = v === null || v === undefined ? '' : String(v);
    // Spreadsheet formula injection: neutralise leading = + - @.
    const safe = /^[=+\-@]/.test(s) ? `'${s}` : s;
    return /[",\n]/.test(safe) ? `"${safe.replace(/"/g, '""')}"` : safe;
  };
  return [cols.join(','), ...rows.map((r) => cols.map((c) => cell(r[c])).join(','))].join('\n') + '\n';
}

export async function logAction(db, email, action, detail = '') {
  try {
    await db.insert('admin_log', { email, action, detail: String(detail).slice(0, 300) });
  } catch { /* before 004_admin.sql */ }
}

/** Failed sign-in attempts for an email in the last 15 minutes. */
export async function recentFailures(db, email, now = Date.now()) {
  try {
    const since = new Date(now - 15 * 60 * 1000).toISOString();
    const rows = await db.select('admin_log',
      `${db.eq('email', email)}&action=eq.login_failed&created_at=gte.${encodeURIComponent(since)}`, 'id');
    return rows.length;
  } catch {
    return 0;
  }
}
