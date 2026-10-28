// Supabase storage for payments (see db/migrations/003_payments.sql).
import { Bachs } from '@bachs/sdk';
import { loadConfig, paymentsOn } from './config.js';
import * as db from './supabase-rest.js';

export const supabaseStore = {
  async getSetting(key) {
    return (await db.select('app_settings', db.eq('key', key), 'value'))[0]?.value ?? null;
  },
  async setSetting(key, value) {
    await db.upsert('app_settings', { key, value, updated_at: new Date().toISOString() }, 'key');
  },
  async getCheckout(activation) {
    return (await db.select('checkouts', db.eq('activation', activation)))[0] ?? null;
  },
  /** Creates the checkout row or merges the given fields into it. */
  async saveCheckout(fields) {
    const existing = await this.getCheckout(fields.activation);
    if (existing) {
      await db.update('checkouts', db.eq('activation', fields.activation), fields);
    } else if (fields.email && fields.plan && fields.currency) {
      await db.insert('checkouts', fields, { ignoreDuplicate: true });
    }
  },
  async getLicense(key) {
    return (await db.select('licenses', db.eq('license_key', key)))[0] ?? null;
  },
  async saveLicense(fields) {
    await db.upsert('licenses', { ...fields, updated_at: new Date().toISOString() }, 'license_key');
  },
  async eventSeen(id) {
    return (await db.select('webhook_events', db.eq('id', id), 'id')).length > 0;
  },
  async markEvent(id, type) {
    await db.insert('webhook_events', { id, type }, { ignoreDuplicate: true });
  },
  async recordPayment(row) {
    try {
      await db.insert('payments', row, { ignoreDuplicate: true });
    } catch (error) {
      // Before 004_admin.sql has been run the table doesn't exist; never lose a licence over it.
      console.error('payment not recorded', error.message);
    }
  },
};

/** Settings from the dashboard, with Vercel variables as fallback. */
export const currentConfig = () => loadConfig(supabaseStore);

/** Bachs API client. Sandbox unless BACHS_ENVIRONMENT=production. */
export function bachsClient(env = process.env) {
  const environment = env.BACHS_ENVIRONMENT === 'production' ? 'production' : 'sandbox';
  if (!env.BACHS_API_KEY) {
    const err = new Error('BACHS_API_KEY is not set.');
    err.status = 503;
    throw err;
  }
  return new Bachs({ apiKey: env.BACHS_API_KEY, environment });
}

export function paymentsConfigured(config) {
  return db.configured() && paymentsOn(config);
}
