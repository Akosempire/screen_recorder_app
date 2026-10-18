import { isEmail, makeToken, LINK_DAYS } from '../lib/token.js';
import { hasDatabase, saveSignup, markEmailSent } from '../lib/db.js';
import { hasEmail, sendDownloadEmail } from '../lib/email.js';

// POST /api/signup  { name, email, updates, website(honeypot) }
// Saves the sign-up to Supabase, then emails a signed download link through SendByte.
export default async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'Use POST.' });
  }
  const secret = process.env.LINK_SECRET;
  if (!secret || !hasDatabase() || !hasEmail()) {
    console.error('signup not configured', { linkSecret: Boolean(secret), database: hasDatabase(), email: hasEmail() });
    return res.status(500).json({ error: 'The site is not set up yet. Try again later.' });
  }

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

  // Save first, so no sign-up is lost even if the email fails.
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

  let messageId;
  try {
    messageId = await sendDownloadEmail({ name, email, link, days: LINK_DAYS });
  } catch (error) {
    console.error('signup email failed', error.message, error.requestId || '');
    if (error.code === 'suppressed_recipient') {
      return res.status(400).json({ error: 'We can’t send email to that address. Try a different one.' });
    }
    return res.status(502).json({ error: 'The link could not be sent. Try again in a minute.' });
  }

  try {
    await markEmailSent(email, messageId);
  } catch (error) {
    console.error('could not record email id', error.message); // the email went out; don't fail the request
  }
  return res.status(200).json({ ok: true });
}
