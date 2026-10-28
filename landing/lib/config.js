// Settings managed from the admin dashboard, stored in Supabase (app_settings),
// with Vercel environment variables as the fallback.
//
// Secrets (Bachs API key, webhook secret, licence secret) are encrypted with
// AES-256-GCM before they're stored. The encryption key comes from
// SETTINGS_KEY, or LINK_SECRET (already set in Vercel). Changing that key
// makes stored secrets unreadable; re-enter them in the dashboard.
import { createCipheriv, createDecipheriv, createHash, randomBytes } from 'node:crypto';

export const SECRET_KEYS = ['bachs_api_key', 'bachs_webhook_secret', 'license_secret'];
export const PLAIN_KEYS = ['bachs_environment', 'payments_enabled', 'admin_emails'];

/** The first admin, so the dashboard can be reached before anything is set up. */
export const DEFAULT_ADMINS = ['akosempire1@gmail.com'];

function cipherKey(env) {
  const base = env.SETTINGS_KEY || env.LINK_SECRET;
  if (!base) throw Object.assign(new Error('LINK_SECRET is not set.'), { status: 503 });
  return createHash('sha256').update(`settings:${base}`).digest();
}

export function encrypt(value, env = process.env) {
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', cipherKey(env), iv);
  const data = Buffer.concat([c.update(String(value), 'utf8'), c.final()]);
  return `v1.${iv.toString('base64url')}.${c.getAuthTag().toString('base64url')}.${data.toString('base64url')}`;
}

export function decrypt(stored, env = process.env) {
  const [v, iv, tag, data] = String(stored).split('.');
  if (v !== 'v1' || !iv || !tag || data === undefined) throw new Error('Unreadable setting');
  const d = createDecipheriv('aes-256-gcm', cipherKey(env), Buffer.from(iv, 'base64url'));
  d.setAuthTag(Buffer.from(tag, 'base64url'));
  return Buffer.concat([d.update(Buffer.from(data, 'base64url')), d.final()]).toString('utf8');
}

const settingName = (key) => `cfg:${key}`;

/**
 * Effective configuration as an env-like object (dashboard values win over
 * Vercel variables). `store` needs getSetting/setSetting.
 */
export async function loadConfig(store, env = process.env) {
  const out = { ...env };
  const read = async (key) => {
    try {
      return await store.getSetting(settingName(key));
    } catch {
      return null;
    }
  };
  const [apiKey, webhook, licence, mode, enabled, admins] = await Promise.all([
    read('bachs_api_key'), read('bachs_webhook_secret'), read('license_secret'),
    read('bachs_environment'), read('payments_enabled'), read('admin_emails'),
  ]);
  const open = (v) => {
    if (!v) return null;
    try { return decrypt(v, env); } catch { return null; }
  };
  out.BACHS_API_KEY = open(apiKey) || env.BACHS_API_KEY || '';
  out.BACHS_WEBHOOK_SECRET = open(webhook) || env.BACHS_WEBHOOK_SECRET || '';
  out.LICENSE_SECRET = open(licence) || env.LICENSE_SECRET || '';
  out.BACHS_ENVIRONMENT = mode || env.BACHS_ENVIRONMENT || 'sandbox';
  // Payments switch: dashboard "off" wins; otherwise on when keys exist.
  out.PAYMENTS_ENABLED = enabled === null || enabled === undefined ? 'auto' : enabled;
  out.ADMIN_EMAILS = admins || env.ADMIN_EMAILS || DEFAULT_ADMINS.join(',');

  // The licence secret must never change once licences exist: create it once.
  if (!out.LICENSE_SECRET && env.LINK_SECRET) {
    const generated = randomBytes(32).toString('base64url');
    try {
      await store.setSetting(settingName('license_secret'), encrypt(generated, env));
      out.LICENSE_SECRET = generated;
    } catch { /* database not ready yet */ }
  }
  return out;
}

export function adminEmails(config) {
  return String(config.ADMIN_EMAILS || '')
    .split(/[\s,;]+/)
    .map((e) => e.trim().toLowerCase())
    .filter((e) => /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(e));
}

/** Whether checkout can work and the free limit should apply. */
export function paymentsOn(config) {
  if (config.PAYMENTS_ENABLED === 'off') return false;
  return Boolean(config.BACHS_API_KEY && config.LICENSE_SECRET && config.BACHS_WEBHOOK_SECRET);
}

/** Saves dashboard settings. Empty secret fields keep the stored value. */
export async function saveSettings(store, input, env = process.env) {
  const changed = [];
  for (const key of SECRET_KEYS) {
    if (key === 'license_secret') continue; // generated once, never edited
    const value = typeof input[key] === 'string' ? input[key].trim() : '';
    if (!value) continue;
    if (key === 'bachs_api_key' && !/^sk_(sandbox|live)_[A-Za-z0-9_-]{8,}$/.test(value)) {
      throw Object.assign(new Error('The Bachs API key should start with sk_sandbox_ or sk_live_.'), { status: 400 });
    }
    if (key === 'bachs_webhook_secret' && !/^whsec_[A-Za-z0-9_-]{8,}$/.test(value)) {
      throw Object.assign(new Error('The webhook signing secret should start with whsec_.'), { status: 400 });
    }
    await store.setSetting(settingName(key), encrypt(value, env));
    changed.push(key);
  }
  if (input.bachs_environment !== undefined) {
    if (!['sandbox', 'production'].includes(input.bachs_environment)) {
      throw Object.assign(new Error('Choose sandbox or live.'), { status: 400 });
    }
    await store.setSetting(settingName('bachs_environment'), input.bachs_environment);
    changed.push('bachs_environment');
  }
  if (input.payments_enabled !== undefined) {
    await store.setSetting(settingName('payments_enabled'), input.payments_enabled ? 'on' : 'off');
    changed.push('payments_enabled');
  }
  if (input.admin_emails !== undefined) {
    const list = adminEmails({ ADMIN_EMAILS: input.admin_emails });
    if (!list.length) throw Object.assign(new Error('Keep at least one admin email.'), { status: 400 });
    await store.setSetting(settingName('admin_emails'), list.join(','));
    changed.push('admin_emails');
  }
  return changed;
}

/** What the dashboard shows: secrets masked, never returned in full. */
export function publicSettings(config) {
  const mask = (v) => (v ? `${v.slice(0, 11)}…${v.slice(-4)}` : null);
  const key = config.BACHS_API_KEY || '';
  return {
    bachs_api_key: mask(key),
    bachs_webhook_secret: mask(config.BACHS_WEBHOOK_SECRET || ''),
    bachs_environment: config.BACHS_ENVIRONMENT === 'production' ? 'production' : 'sandbox',
    key_matches_environment: !key || (config.BACHS_ENVIRONMENT === 'production' ? key.startsWith('sk_live_') : key.startsWith('sk_sandbox_')),
    payments_enabled: config.PAYMENTS_ENABLED !== 'off',
    payments_live: paymentsOn(config),
    admin_emails: adminEmails(config),
    licence_secret_ready: Boolean(config.LICENSE_SECRET),
    webhook_url: `${(config.SITE_URL || 'https://screenrecorderapp.vercel.app').replace(/\/+$/, '')}/api/bachs-webhook`,
  };
}
