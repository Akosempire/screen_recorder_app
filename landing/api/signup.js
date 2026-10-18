import { isEmail, makeToken, sendToSheet, LINK_DAYS } from '../lib/token.js';

// POST /api/signup  { name, email, updates, website(honeypot) }
// Saves the sign-up to the Google Sheet and emails a signed download link.
export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'Use POST.' });
  }
  const secret = process.env.LINK_SECRET;
  if (!secret) return res.status(500).json({ error: 'The site is not set up yet. Try again later.' });

  let body = req.body;
  if (typeof body === 'string') {
    try { body = JSON.parse(body); } catch { body = {}; }
  }
  body = body || {};

  // Bots fill the hidden field; pretend it worked.
  if (body.website) return res.status(200).json({ ok: true });

  const name = String(body.name || '').trim().slice(0, 80);
  const email = String(body.email || '').trim().toLowerCase();
  if (!name) return res.status(400).json({ error: 'Enter your name.' });
  if (!isEmail(email)) return res.status(400).json({ error: 'Enter a valid email address, like you@example.com.' });

  const proto = req.headers['x-forwarded-proto'] || 'https';
  const host = process.env.PUBLIC_URL?.replace(/\/+$/, '') || `${proto}://${req.headers.host}`;
  const link = `${host}/api/download?t=${makeToken(email, secret)}`;

  try {
    await sendToSheet({
      action: 'signup',
      name,
      email,
      updates: Boolean(body.updates),
      link,
      linkDays: LINK_DAYS,
      country: req.headers['x-vercel-ip-country'] || '',
      userAgent: String(req.headers['user-agent'] || '').slice(0, 200),
    });
  } catch (error) {
    console.error('signup failed', error);
    return res.status(502).json({ error: 'The link could not be sent. Try again in a minute.' });
  }
  return res.status(200).json({ ok: true });
}
