import { brevoReady, sendEmail } from '../lib/brevo.js';
import { supabaseStore } from '../lib/billing-store.js';
import { adminEmails, loadConfig } from '../lib/config.js';
import { readJson } from '../lib/http.js';
import { readRequest, requestEmail, saveRequest } from '../lib/support.js';
import * as db from '../lib/supabase-rest.js';

// A few requests per address per hour is plenty for a real person.
const recent = new Map();
export function tooMany(ip, now = Date.now(), limit = 6) {
  const hits = (recent.get(ip) || []).filter((t) => now - t < 60 * 60 * 1000);
  if (hits.length >= limit) return true;
  recent.set(ip, [...hits, now]);
  return false;
}

// POST /api/support { kind, message, email?, source, appVersion, os, details?, website(honeypot) }
// "Get help" in the app. Saved for the admin dashboard (Help requests) and
// emailed to the admins when email is set up.
export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'Use POST.' });
  }
  if (!db.configured()) return res.status(503).json({ error: 'Help requests aren’t set up yet. Try again later.' });
  let body;
  try { body = await readJson(req); } catch { body = {}; }
  if (body.website) return res.status(200).json({ ok: true });
  const ip = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim() || 'unknown';
  if (tooMany(ip)) return res.status(429).json({ error: 'You’ve sent a few already. We’ll get back to you; try again in an hour if needed.' });

  const { row, error } = readRequest(body, req.headers);
  if (error) return res.status(400).json({ error });
  try {
    await saveRequest(db, row);
  } catch (err) {
    console.error('support save failed', err.message);
    return res.status(500).json({ error: 'We couldn’t save your message. Try again in a minute.' });
  }
  try {
    const config = await loadConfig(supabaseStore);
    if (brevoReady(config)) {
      const mail = requestEmail(row);
      await Promise.race([
        Promise.all(adminEmails(config).map((to) => sendEmail(config, { to, ...mail }).catch((e) => console.error('support email failed', e.message)))),
        new Promise((resolve) => setTimeout(resolve, 4000)),
      ]);
    }
  } catch (err) {
    console.error('support email failed', err.message);
  }
  return res.status(200).json({ ok: true });
}
