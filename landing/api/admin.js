import {
  clearCookie, makeSession, readCookie, readSession, sendCode, sessionCookie, verifyCode,
} from '../lib/admin-auth.js';
import {
  grantLicense, listLicenses, listPeople, logAction, overview, recentFailures, setRevoked, toCsv,
} from '../lib/admin.js';
import { bachsClient, supabaseStore } from '../lib/billing-store.js';
import { adminEmails, loadConfig, publicSettings, saveSettings } from '../lib/config.js';
import { readJson, sendError } from '../lib/http.js';
import * as db from '../lib/supabase-rest.js';

// /api/admin?action=…  The admin dashboard's only endpoint.
// Signed-out actions: login (send code), verify (check code, set cookie).
// Everything else needs the admin session cookie. Writes must be POST with a
// JSON body (SameSite=Strict cookie + JSON keeps other sites from posting).
export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Robots-Tag', 'noindex');
  try {
    if (!db.configured()) return res.status(503).json({ error: 'Connect Supabase first (SUPABASE_URL in Vercel).' });
    const url = new URL(req.url, 'http://local');
    const action = url.searchParams.get('action') || '';
    const config = await loadConfig(supabaseStore);
    const admins = adminEmails(config);

    if (req.method === 'POST' && !String(req.headers['content-type'] || '').includes('application/json')) {
      return res.status(415).json({ error: 'Send JSON.' });
    }

    // ---- signing in ----
    if (action === 'login' && req.method === 'POST') {
      const email = String((await readJson(req)).email || '').trim().toLowerCase();
      // Same answer whether or not the email is an admin (no list probing).
      if (admins.includes(email)) {
        if (await recentFailures(db, email) >= 5) {
          return res.status(429).json({ error: 'Too many wrong codes. Wait 15 minutes and try again.' });
        }
        await sendCode(email);
      }
      return res.status(200).json({ ok: true, message: 'If this email is an admin, a 6-digit code is on its way.' });
    }
    if (action === 'verify' && req.method === 'POST') {
      const body = await readJson(req);
      const email = String(body.email || '').trim().toLowerCase();
      if (!admins.includes(email)) return res.status(401).json({ error: 'That code is not right or has expired.' });
      if (await recentFailures(db, email) >= 5) {
        return res.status(429).json({ error: 'Too many wrong codes. Wait 15 minutes and try again.' });
      }
      if (!(await verifyCode(email, String(body.code || '').trim()))) {
        await logAction(db, email, 'login_failed');
        return res.status(401).json({ error: 'That code is not right or has expired.' });
      }
      await logAction(db, email, 'login');
      res.setHeader('Set-Cookie', sessionCookie(makeSession(email)));
      return res.status(200).json({ ok: true, email });
    }
    if (action === 'logout') {
      res.setHeader('Set-Cookie', clearCookie());
      return res.status(200).json({ ok: true });
    }

    // ---- everything below needs a session ----
    const me = readSession(readCookie(req), admins);
    if (!me) return res.status(401).json({ error: 'Please sign in.' });

    if (req.method === 'GET') {
      switch (action) {
        case 'me':
          return res.status(200).json({ email: me });
        case 'overview':
          return res.status(200).json({ ...(await overview(db)), settings: publicSettings(config) });
        case 'licenses':
          return res.status(200).json({ items: await listLicenses(db, url.searchParams.get('q')) });
        case 'downloads':
        case 'signups': {
          const items = await listPeople(db, action, url.searchParams.get('q'));
          if (url.searchParams.get('format') === 'csv') {
            res.setHeader('Content-Type', 'text/csv; charset=utf-8');
            res.setHeader('Content-Disposition', `attachment; filename="${action}.csv"`);
            return res.status(200).send(toCsv(items));
          }
          return res.status(200).json({ items });
        }
        case 'settings':
          return res.status(200).json(publicSettings(config));
        case 'log':
          return res.status(200).json({ items: await db.select('admin_log', 'order=created_at.desc&limit=100').catch(() => []) });
        default:
          return res.status(404).json({ error: 'Unknown action.' });
      }
    }

    if (req.method === 'POST') {
      const body = await readJson(req);
      switch (action) {
        case 'settings': {
          const changed = await saveSettings(supabaseStore, body);
          await logAction(db, me, 'settings', changed.join(', '));
          return res.status(200).json(publicSettings(await loadConfig(supabaseStore)));
        }
        case 'test-bachs': {
          const fresh = await loadConfig(supabaseStore);
          try {
            await bachsClient(fresh).products.list({ limit: 1 });
            return res.status(200).json({ ok: true, message: `Connected to Bachs (${fresh.BACHS_ENVIRONMENT === 'production' ? 'live' : 'sandbox'}).` });
          } catch (error) {
            return res.status(200).json({ ok: false, message: `Bachs said: ${error.message}` });
          }
        }
        case 'grant': {
          const row = await grantLicense(db, body, config);
          await logAction(db, me, 'grant', `${row.plan} ${row.email} ${row.license_key}`);
          return res.status(200).json(row);
        }
        case 'revoke':
        case 'restore': {
          const row = await setRevoked(db, String(body.key || '').toUpperCase(), action === 'revoke');
          await logAction(db, me, action, row.license_key);
          return res.status(200).json(row);
        }
        default:
          return res.status(404).json({ error: 'Unknown action.' });
      }
    }
    res.setHeader('Allow', 'GET, POST');
    return res.status(405).json({ error: 'Use GET or POST.' });
  } catch (error) {
    return sendError(res, error, 'Something went wrong. Try again.');
  }
}
