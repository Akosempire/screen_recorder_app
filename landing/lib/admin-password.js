// Admin sign-in: password + a 6-digit code from an authenticator app (Google
// Authenticator, Microsoft Authenticator, 1Password…). No emails involved.
//
// Stored per admin in app_settings as `admin_auth:<email>`:
//   { pw: scrypt hash, totp: encrypted secret, last: last code step used }
// The first setup needs a one-time setup token (its SHA-256 is below, or
// ADMIN_SETUP_TOKEN in Vercel). Once used, that token stops working; a new
// token hash re-opens setup (for a lost phone).
import { createHash, createHmac, randomBytes, scrypt, timingSafeEqual } from 'node:crypto';
import QRCode from 'qrcode';
import { decrypt, encrypt } from './config.js';

export const SETUP_TOKEN_SHA256 = '576436810c5d44bd87b2d33bc7635176da76c261fcaa3db3493722115a1f0711';

const scryptAsync = (pw, salt) => new Promise((resolve, reject) =>
  scrypt(pw, salt, 64, { N: 16384, r: 8, p: 1 }, (err, key) => (err ? reject(err) : resolve(key))));

export const MIN_PASSWORD = 10;

export async function hashPassword(password) {
  const salt = randomBytes(16);
  const key = await scryptAsync(String(password), salt);
  return `scrypt.${salt.toString('base64url')}.${key.toString('base64url')}`;
}

export async function checkPassword(password, stored) {
  const [kind, salt, hash] = String(stored || '').split('.');
  if (kind !== 'scrypt' || !salt || !hash) return false;
  const key = await scryptAsync(String(password), Buffer.from(salt, 'base64url'));
  const expected = Buffer.from(hash, 'base64url');
  return key.length === expected.length && timingSafeEqual(key, expected);
}

export function passwordProblem(password) {
  const p = String(password || '');
  if (p.length < MIN_PASSWORD) return `Use at least ${MIN_PASSWORD} characters.`;
  if (p.length > 200) return 'That password is too long.';
  if (/^(.)\1+$/.test(p) || /^(0123456789|1234567890|password\d*|qwertyuiop)/i.test(p)) return 'Pick a less guessable password.';
  return null;
}

// ---- TOTP (RFC 6238: SHA-1, 30 s, 6 digits) -------------------------------------

const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function base32(buf) {
  let bits = 0, value = 0, out = '';
  for (const byte of buf) {
    value = (value << 8) | byte; bits += 8;
    while (bits >= 5) { out += B32[(value >>> (bits - 5)) & 31]; bits -= 5; }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

export function fromBase32(text) {
  let bits = 0, value = 0;
  const out = [];
  for (const ch of String(text).toUpperCase().replace(/[^A-Z2-7]/g, '')) {
    value = (value << 5) | B32.indexOf(ch); bits += 5;
    if (bits >= 8) { out.push((value >>> (bits - 8)) & 255); bits -= 8; }
  }
  return Buffer.from(out);
}

export const newTotpSecret = () => base32(randomBytes(20));

export function totpAt(secret, step) {
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(step));
  const mac = createHmac('sha1', fromBase32(secret)).update(counter).digest();
  const offset = mac[mac.length - 1] & 15;
  const n = (mac.readUInt32BE(offset) & 0x7fffffff) % 1000000;
  return String(n).padStart(6, '0');
}

/** The time step the code matches (allowing ±1 step of clock drift), or null. */
export function matchTotp(secret, code, now = Date.now(), after = -1) {
  if (!/^\d{6}$/.test(String(code))) return null;
  const step = Math.floor(now / 30000);
  for (const s of [step, step - 1, step + 1]) {
    if (s <= after) continue; // each code works once
    const a = Buffer.from(totpAt(secret, s));
    if (timingSafeEqual(a, Buffer.from(String(code)))) return s;
  }
  return null;
}

export function otpauthUri(secret, email) {
  const label = encodeURIComponent(`Screen Recorder:${email}`);
  return `otpauth://totp/${label}?secret=${secret}&issuer=${encodeURIComponent('Screen Recorder')}&algorithm=SHA1&digits=6&period=30`;
}

export const qrSvg = (uri) => QRCode.toString(uri, { type: 'svg', margin: 1, errorCorrectionLevel: 'M' });

// ---- storage ---------------------------------------------------------------------

const authKey = (email) => `admin_auth:${email}`;
const pendingKey = (email) => `admin_pending:${email}`;

async function readJson(store, key) {
  try { return JSON.parse((await store.getSetting(key)) || 'null'); } catch { return null; }
}

export const getAuth = (store, email) => readJson(store, authKey(email));

/** Whether this email has a password and authenticator set up. */
export async function hasAuth(store, email) {
  const a = await getAuth(store, email);
  return Boolean(a && a.pw && a.totp);
}

// ---- setup token -------------------------------------------------------------------

const sha256 = (s) => createHash('sha256').update(String(s)).digest('hex');

function tokenHash(env) {
  return env.ADMIN_SETUP_TOKEN ? sha256(env.ADMIN_SETUP_TOKEN) : SETUP_TOKEN_SHA256;
}

/** True when the token is the current setup token and hasn't been used yet. */
export async function setupTokenValid(store, token, env = process.env) {
  if (typeof token !== 'string' || token.length < 20) return false;
  const want = Buffer.from(tokenHash(env));
  const got = Buffer.from(sha256(token));
  if (want.length !== got.length || !timingSafeEqual(want, got)) return false;
  const used = await store.getSetting('admin_setup_used').catch(() => null);
  return used !== tokenHash(env);
}

/** Whether the setup screen should be offered at all (token not yet used). */
export async function setupOpen(store, env = process.env) {
  const used = await store.getSetting('admin_setup_used').catch(() => null);
  return used !== tokenHash(env);
}

// ---- flows -------------------------------------------------------------------------

/**
 * Step 1 of setting up (or changing) a password + authenticator: stores the
 * new password hash and a new secret as pending for 15 minutes, and returns
 * what the authenticator app needs.
 */
export async function startSetup(store, email, password, env = process.env, now = Date.now()) {
  const problem = passwordProblem(password);
  if (problem) throw Object.assign(new Error(problem), { status: 400 });
  const secret = newTotpSecret();
  await store.setSetting(pendingKey(email), JSON.stringify({
    pw: await hashPassword(password),
    totp: encrypt(secret, env),
    x: now + 15 * 60 * 1000,
  }));
  const uri = otpauthUri(secret, email);
  return { secret: secret.replace(/(.{4})/g, '$1 ').trim(), uri, qr: await qrSvg(uri) };
}

/** Step 2: the first code from the app confirms the pending setup. */
export async function finishSetup(store, email, code, env = process.env, now = Date.now()) {
  const pending = await readJson(store, pendingKey(email));
  if (!pending || !(pending.x > now)) {
    throw Object.assign(new Error('This setup has expired. Start again.'), { status: 400 });
  }
  const secret = decrypt(pending.totp, env);
  const step = matchTotp(secret, code, now);
  if (step === null) {
    throw Object.assign(new Error('That code doesn\'t match. Check the app shows "Screen Recorder" and try the newest code.'), { status: 400 });
  }
  await store.setSetting(authKey(email), JSON.stringify({ pw: pending.pw, totp: pending.totp, last: step }));
  await store.setSetting(pendingKey(email), '{}');
}

/** Checks password + authenticator code. Returns true or false. */
export async function signIn(store, email, password, code, env = process.env, now = Date.now()) {
  const auth = await getAuth(store, email);
  // Do the slow password check even for unknown emails, so timing doesn't tell.
  const pwOk = await checkPassword(password, auth?.pw || 'scrypt.AAAAAAAAAAAAAAAAAAAAAA.AAAA');
  if (!auth || !auth.pw || !auth.totp || !pwOk) return false;
  let secret;
  try { secret = decrypt(auth.totp, env); } catch { return false; }
  const step = matchTotp(secret, code, now, Number.isInteger(auth.last) ? auth.last : -1);
  if (step === null) return false;
  await store.setSetting(authKey(email), JSON.stringify({ ...auth, last: step }));
  return true;
}

export const markSetupUsed = (store, env = process.env) => store.setSetting('admin_setup_used', tokenHash(env));
