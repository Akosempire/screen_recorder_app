import { isEmail, makeToken } from '../lib/token.js';
import { hasDatabase, saveSignup } from '../lib/db.js';

// POST /api/signup  { name, email, updates, website(honeypot) }
// Saves the sign-up to Supabase, then returns a signed download link for the
// page to start straight away. (No email is sent; lib/email.js is kept for later.)
export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'Use POST.' });
  }
  const secret = process.env.LINK_SECRET;
  if (!secret || !hasDatabase()) {
    console.error('signup not configured', { linkSecret: Boolean(secret), database: hasDatabase() });
    return res.status(500).json({ error: 'The site is not set up yet. Try again later.' });
  }

  let body = req.body;
  if (typeof body === 'string') {
    try { body = JSON.parse(body); } catch { body = {}; }
  }
  body = body || {};

  // Bots fill the hidden field; pretend it worked but give them nothing.
  if (body.website) return res.status(200).json({ ok: true });

  const name = String(body.name || '').trim().slice(0, 80);
  const email = String(body.email || '').trim().toLowerCase();
  if (!name) return res.status(400).json({ error: 'Enter your name.' });
  if (!isEmail(email)) return res.status(400).json({ error: 'Enter a valid email address, like you@example.com.' });

  try {
    await saveSignup({
      name,
      email,
      updates: body.updates,
      country: req.headers['x-vercel-ip-country'] || '',
      userAgent: String(req.headers['user-agent'] || '').slice(0, 200),
    });
  } catch (error) {
    console.error('signup save failed', error);
    return res.status(502).json({ error: 'We could not save your details. Try again in a minute.' });
  }

  // Same-site path: /api/download checks the signature, logs the download and
  // redirects to the installer.
  res.setHeader('Cache-Control', 'no-store');
  return res.status(200).json({ ok: true, downloadUrl: `/api/download?t=${makeToken(email, secret)}` });
}
