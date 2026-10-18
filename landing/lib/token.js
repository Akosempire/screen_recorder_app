import crypto from 'node:crypto';

// Signed, expiring download tokens: base64url(json).base64url(hmac).
// Only this site (which knows LINK_SECRET) can make a valid one.

const b64url = (buf) =>
  Buffer.from(buf).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
const fromB64url = (s) => Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64');

export const LINK_DAYS = 7;

export function makeToken(email, secret, now = Date.now()) {
  const payload = b64url(JSON.stringify({ e: email, x: now + LINK_DAYS * 864e5 }));
  const sig = b64url(crypto.createHmac('sha256', secret).update(payload).digest());
  return `${payload}.${sig}`;
}

/** Returns the email for a valid, unexpired token, otherwise null. */
export function readToken(token, secret, now = Date.now()) {
  if (typeof token !== 'string' || token.length > 600) return null;
  const [payload, sig] = token.split('.');
  if (!payload || !sig) return null;
  const expected = b64url(crypto.createHmac('sha256', secret).update(payload).digest());
  const a = Buffer.from(sig);
  const b = Buffer.from(expected);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
  try {
    const data = JSON.parse(fromB64url(payload).toString('utf8'));
    if (typeof data.e !== 'string' || typeof data.x !== 'number') return null;
    if (data.x < now) return null;
    return data.e;
  } catch {
    return null;
  }
}

export function isEmail(value) {
  return typeof value === 'string' && value.length <= 160 && /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(value);
}

/** Forwards an event to the Google Apps Script web app bound to the Sheet. */
export async function sendToSheet(body, { url = process.env.APPS_SCRIPT_URL, secret = process.env.APPS_SCRIPT_SECRET } = {}) {
  if (!url || !secret) throw new Error('Sign-up storage is not configured.');
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...body, secret }),
    redirect: 'follow',
  });
  const text = await res.text();
  let data = {};
  try { data = JSON.parse(text); } catch { /* Apps Script returned HTML */ }
  if (!res.ok || data.ok !== true) {
    throw new Error(data.error || `Apps Script responded ${res.status}`);
  }
  return data;
}
