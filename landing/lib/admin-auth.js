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
  const err = new Error(res.status === 429
    ? 'Too many codes requested. Wait a few minutes and try again.'
    : 'The code could not be sent. Try again in a minute.');
  err.status = res.status === 429 ? 429 : 502;
  err.detail = data.msg || data.message || data.error_description || '';
  throw err;
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
