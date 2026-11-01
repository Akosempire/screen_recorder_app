import { clearCookie, makeSession, readCookie, readSession, sessionCookie } from '../lib/admin-auth.js';
import {
  finishSetup, markSetupUsed, setupOpen, setupTokenValid, signIn, startSetup,
} from '../lib/admin-password.js';
import { sendEmail } from '../lib/brevo.js';
import {
  grantLicense, listLicenses, listPeople, logAction, overview, recentFailures, setRevoked, toCsv,
} from '../lib/admin.js';
import { bachsClient, supabaseStore } from '../lib/billing-store.js';
import { testCheckout } from '../lib/billing.js';
import { adminEmails, loadConfig, publicSettings, saveSettings } from '../lib/config.js';
import { readJson, sendError } from '../lib/http.js';
import * as db from '../lib/supabase-rest.js';

// /api/admin?action=…  The admin dashboard's only endpoint.
// Signed-out actions: status, login (password + authenticator code),
// setup-start / setup-finish (first time, with the one-time setup token).
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

    // ---- signing in: password + authenticator code ----
    const tooMany = () => res.status(429).json({ error: 'Too many wrong attempts. Wait 15 minutes and try again.' });
    if (action === 'status' && req.method === 'GET') {
      return res.status(200).json({ setupOpen: await setupOpen(supabaseStore) });
    }
    if (action === 'login' && req.method === 'POST') {
      const body = await readJson(req);
      const email = String(body.email || '').trim().toLowerCase();
      if (await recentFailures(db, email) >= 5) return tooMany();
      const ok = admins.includes(email)
        && await signIn(supabaseStore, email, String(body.password || ''), String(body.code || '').replace(/\s/g, ''));
      if (!ok) {
        if (email) await logAction(db, email.slice(0, 160), 'login_failed');
        return res.status(401).json({ error: 'Email, password or code is not right.' });
      }
      await logAction(db, email, 'login');
      res.setHeader('Set-Cookie', sessionCookie(makeSession(email)));
      return res.status(200).json({ ok: true, email });
    }
    // First-time setup (or after a lost phone), with the one-time setup token.
    if ((action === 'setup-start' || action === 'setup-finish') && req.method === 'POST') {
      const body = await readJson(req);
      const email = String(body.email || '').trim().toLowerCase();
      if (await recentFailures(db, 'setup') >= 10) return tooMany();
      if (!(await setupTokenValid(supabaseStore, String(body.token || '')))) {
        await logAction(db, 'setup', 'login_failed', 'bad setup link');
        return res.status(401).json({ error: 'This setup link is not valid or was already used.' });
      }
      if (!admins.includes(email)) return res.status(400).json({ error: `Use an admin email (${admins[0]}).` });
      if (action === 'setup-start') {
        return res.status(200).json(await startSetup(supabaseStore, email, body.password));
      }
      await finishSetup(supabaseStore, email, String(body.code || '').replace(/\s/g, ''));
      await markSetupUsed(supabaseStore);
      await logAction(db, email, 'setup', 'password and authenticator set');
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
          let bachs;
          try { bachs = bachsClient(fresh); } catch (error) {
            return res.status(200).json({ ok: false, message: error.message, steps: [] });
          }
          const result = await testCheckout({ store: supabaseStore, bachs, env: fresh, email: me });
          const failed = result.steps.find((s) => !s.ok);
          await logAction(db, me, 'test_bachs', failed ? `${failed.name}: ${failed.detail}` : 'all steps passed');
          return res.status(200).json({
            ...result,
            message: failed ? `${failed.name} failed: ${failed.detail}` : `Everything works (${fresh.BACHS_ENVIRONMENT === 'production' ? 'live' : 'sandbox'}): buyers can pay ($5 a month or $50 once).`,
          });
        }
        case 'change-start':
          return res.status(200).json(await startSetup(supabaseStore, me, body.password));
        case 'change-finish':
          await finishSetup(supabaseStore, me, String(body.code || '').replace(/\s/g, ''));
          await logAction(db, me, 'setup', 'changed password and authenticator');
          return res.status(200).json({ ok: true });
        case 'test-email': {
          const fresh = await loadConfig(supabaseStore);
          try {
            await sendEmail(fresh, {
              to: me,
              subject: 'Screen Recorder test email',
              html: '<p>This is a test from your Screen Recorder dashboard. Email through Brevo works.</p>',
              text: 'This is a test from your Screen Recorder dashboard. Email through Brevo works.',
            });
            await logAction(db, me, 'test_email', 'sent');
            return res.status(200).json({ ok: true, message: `Sent a test email to ${me} from ${fresh.EMAIL_FROM}. Check your inbox (and spam).` });
          } catch (error) {
            await logAction(db, me, 'test_email', error.message);
            return res.status(200).json({ ok: false, message: error.message });
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
