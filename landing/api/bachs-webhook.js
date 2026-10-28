import { webhooks, BachsWebhookError } from '@bachs/sdk';
import { handleEvent } from '../lib/billing.js';
import { currentConfig, supabaseStore } from '../lib/billing-store.js';
import { readRaw } from '../lib/http.js';

// POST /api/bachs-webhook  (register this URL in the Bachs dashboard)
// Verifies the signature on the raw bytes, then grants or updates licences.
export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).end();
  }
  const config = await currentConfig();
  const secret = config.BACHS_WEBHOOK_SECRET;
  if (!secret) return res.status(500).send('Webhook secret is not configured');

  let event;
  try {
    event = webhooks.constructEvent(await readRaw(req), req.headers, secret);
  } catch (error) {
    if (error instanceof BachsWebhookError) return res.status(400).send('Invalid webhook');
    console.error('webhook verification failed', error.message);
    return res.status(500).send('Verification failed');
  }

  try {
    const result = await handleEvent(event, { store: supabaseStore, env: config });
    console.log('bachs webhook', event.type, event.id, result);
    return res.status(200).send('OK');
  } catch (error) {
    // 5xx makes Bachs retry later.
    console.error('bachs webhook failed', event.type, event.id, error.message);
    return res.status(500).send('Could not handle event');
  }
}
