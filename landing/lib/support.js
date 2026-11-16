import { isEmail } from './token.js';

export const KINDS = ['problem', 'question', 'idea'];

/** Checks and tidies a help request; returns { row } or { error }. */
export function readRequest(body = {}, headers = {}) {
  const message = String(body.message || '').trim();
  if (message.length < 5) return { error: 'Tell us a little more about what happened.' };
  const email = String(body.email || '').trim().toLowerCase();
  if (email && !isEmail(email)) return { error: 'That email doesn’t look right. Leave it empty, or use one like you@example.com.' };
  const clip = (v, n) => (v === undefined || v === null ? null : String(v).slice(0, n) || null);
  return {
    row: {
      kind: KINDS.includes(body.kind) ? body.kind : 'problem',
      message: message.slice(0, 5000),
      email: email || null,
      source: ['app', 'extension', 'website'].includes(body.source) ? body.source : 'app',
      app_version: clip(body.appVersion, 40),
      os: clip(body.os, 120),
      details: clip(body.details, 20000),
      country: clip(headers['x-vercel-ip-country'], 8),
    },
  };
}

/** Saves to support_requests; if that table doesn't exist yet, to admin_log. */
export async function saveRequest(db, row) {
  try {
    const saved = await db.insert('support_requests', row);
    return { stored: 'support_requests', id: saved?.id ?? null };
  } catch (error) {
    console.error('support_requests insert failed; using admin_log', error.message);
    await db.insert('admin_log', {
      email: row.email || 'app user',
      action: `help_${row.kind}`,
      detail: `${row.message} [${row.app_version || '?'} · ${row.os || '?'}]`.slice(0, 300),
    });
    return { stored: 'admin_log' };
  }
}

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

/** The email admins get for each new request. */
export function requestEmail(row) {
  const label = { problem: 'Problem', question: 'Question', idea: 'Idea' }[row.kind] || 'Help request';
  const subject = `${label} from ${row.email || 'a user'}: ${row.message.slice(0, 60)}${row.message.length > 60 ? '…' : ''}`;
  const meta = [row.app_version && `Version ${row.app_version}`, row.os, row.country].filter(Boolean).join(' · ');
  const text = `${row.message}\n\nFrom: ${row.email || 'no email given'}\n${meta}\n\nSee all requests: https://screenrecorderapp.vercel.app/admin#support`;
  const html = `<p style="white-space:pre-wrap">${esc(row.message)}</p><p>From: ${row.email ? `<a href="mailto:${esc(row.email)}">${esc(row.email)}</a>` : 'no email given'}<br>${esc(meta)}</p><p><a href="https://screenrecorderapp.vercel.app/admin#support">Open Help requests</a></p>`;
  return { subject, text, html };
}
