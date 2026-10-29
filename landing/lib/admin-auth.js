// Admin sign-in: a 6-digit code emailed by Supabase Auth, then a signed,
// HttpOnly session cookie (12 hours). Only emails in the admin list can sign in.
import { createHmac, timingSafeEqual } from 'node:crypto';

export const COOKIE = '__Host-sr_admin';
const SESSION_MS = 12 * 3600 * 1000;

function sessionKey(env) {
  const base = env.SETTINGS_KEY || env.LINK_SECRET;
  if (!base) throw Object.assign(new Error('LINK_SECRET is not set.'), { status: 503 });
  return createHmac('sha256', base).update('admin-session').digest();
}

export function makeSession(email, env = process.env, now = Date.now()) {
  const payload = Buffer.from(JSON.stringify({ e: email, x: now + SESSION_MS })).toString('base64url');
  const sig = createHmac('sha256', sessionKey(env)).update(payload).digest('base64url');
  return `${payload}.${sig}`;
}

/** The signed-in admin's email, or null. Also checks the admin list. */
export function readSession(token, allowed, env = process.env, now = Date.now()) {
  if (typeof token !== 'string' || !token.includes('.')) return null;
  const [payload, sig] = token.split('.');
  const expected = createHmac('sha256', sessionKey(env)).update(payload).digest();
  let given;
  try { given = Buffer.from(sig, 'base64url'); } catch { return null; }
  if (given.length !== expected.length || !timingSafeEqual(given, expected)) return null;
  let data;
  try { data = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8')); } catch { return null; }
  if (!data || typeof data.e !== 'string' || !(data.x > now)) return null;
  return allowed.includes(data.e.toLowerCase()) ? data.e.toLowerCase() : null;
}

export function sessionCookie(token) {
  return `${COOKIE}=${token}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${SESSION_MS / 1000}`;
}

export const clearCookie = () => `${COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0`;

export function readCookie(req, name = COOKIE) {
  const raw = req.headers?.cookie || '';
  for (const part of raw.split(';')) {
    const [k, ...v] = part.trim().split('=');
    if (k === name) return v.join('=');
  }
  return null;
}

// ---- Supabase Auth email codes -------------------------------------------------

function supabase(env) {
  const url = (env.SUPABASE_URL || '').replace(/\/+$/, '');
  const key = env.SUPABASE_SERVICE_ROLE_KEY || '';
  if (!url || !key) throw Object.assign(new Error('Supabase is not connected.'), { status: 503 });
  return { url, headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' } };
}

/** Turns Supabase's refusal into a message that says what to fix. */
export function codeError(status, detail = '') {
  const d = detail.toLowerCase();
  let message;
  if (status === 429 || d.includes('rate limit') || d.includes('security purposes')) {
    message = 'Supabase is limiting emails right now. Wait a few minutes and try again.';
  } else if (d.includes('not authorized') || d.includes('not allowed to send')) {
    message = 'Supabase\'s built-in email only sends to members of your Supabase team. Invite this email in Supabase → Organization → Team (or set up custom SMTP), then try again.';
  } else if (d.includes('smtp') || d.includes('sending') || d.includes('email')) {
    message = 'Supabase could not send the email. In Supabase → Authentication → Emails → SMTP Settings, turn custom SMTP off (or finish its settings), then try again.';
  } else if (d.includes('signup') || d.includes('sign up') || status === 422) {
    message = 'Supabase is not allowing new sign-ins. In Supabase → Authentication → Sign In / Providers, turn on "Allow new users to sign up" and make sure Email is enabled.';
  } else if (status === 401 || status === 403) {
    message = 'The website\'s Supabase key was refused. Check SUPABASE_SERVICE_ROLE_KEY in Vercel matches Supabase → Project Settings → API keys.';
  } else {
    message = `The code could not be sent (Supabase said: ${detail || `error ${status}`}).`;
  }
  if (detail && !message.includes(detail)) message += ` (Supabase said: ${detail})`;
  const err = new Error(message);
  err.status = status === 429 ? 429 : 400; // shown to the admin as-is
  err.detail = detail;
  return err;
}

/** Emails a sign-in code (Supabase's "Magic Link" email; its template must show {{ .Token }}). */
export async function sendCode(email, env = process.env, fetcher = fetch) {
  const { url, headers } = supabase(env);
  const res = await fetcher(`${url}/auth/v1/otp`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ email, create_user: true, data: { role: 'admin' } }),
    signal: AbortSignal.timeout(10000),
  });
  if (res.ok) return;
  const data = await res.json().catch(() => ({}));
  const detail = String(data.msg || data.message || data.error_description || data.error || '');
  console.error('Supabase /otp failed', res.status, detail);
  throw codeError(res.status, detail);
}

/** True when the code is right (Supabase checks it and its expiry). */
export async function verifyCode(email, code, env = process.env, fetcher = fetch) {
  if (!/^\d{6,8}$/.test(String(code))) return false;
  const { url, headers } = supabase(env);
  const res = await fetcher(`${url}/auth/v1/verify`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ type: 'email', email, token: String(code) }),
    signal: AbortSignal.timeout(10000),
  });
  return res.ok;
}
