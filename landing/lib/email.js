import crypto from 'node:crypto';

// Download-link email, sent through SendByte (https://docs.sendbyte.africa).
const API = () => (process.env.SENDBYTE_API_URL || 'https://api.sendbyte.africa/v1').replace(/\/+$/, '');
export const SUPPORT_URL = 'https://buymeamalt.com/@ibrahim_designer';

export function hasEmail() {
  return Boolean(process.env.SENDBYTE_API_KEY && process.env.EMAIL_FROM);
}

const escape = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

export function downloadEmail({ name, link, days }) {
  const first = String(name || '').trim().split(/\s+/)[0] || 'there';
  const html =
    '<div style="font-family:Segoe UI,Arial,sans-serif;color:#15171A;max-width:480px;line-height:1.55">' +
    `<p>Hi ${escape(first)},</p>` +
    '<p>Here is your download link for Screen Recorder for Windows:</p>' +
    `<p style="margin:24px 0"><a href="${escape(link)}" style="background:#15171A;color:#ffffff;` +
    'text-decoration:none;font-weight:600;padding:12px 18px;border-radius:10px;display:inline-block">' +
    'Download Screen Recorder</a></p>' +
    '<p>Open <b>ScreenRecorder-Setup.exe</b> and a Screen Recorder shortcut appears on your desktop. ' +
    'If Windows says "Windows protected your PC", click <b>More info</b>, then <b>Run anyway</b>.</p>' +
    '<div style="margin:24px 0;padding:16px 18px;border-radius:12px;background:#FFF8DC;border:1px solid #F3E2A0">' +
    '<p style="margin:0 0 10px">Enjoying the app? Buy me suya to keep it running.</p>' +
    `<a href="${SUPPORT_URL}" style="color:#15171A;font-weight:600">Buy me suya</a></div>` +
    `<p style="color:#5E6670;font-size:13px">This link works for ${days} days. ` +
    'You received this because you asked for the download on our website.</p>' +
    '</div>';
  const text =
    `Hi ${first},\n\nDownload Screen Recorder for Windows: ${link}\n\n` +
    `This link works for ${days} days.\n\n` +
    `Enjoying the app? Buy me suya to keep it running: ${SUPPORT_URL}\n`;
  return { subject: 'Your Screen Recorder download link', html, text };
}

/**
 * Sends the download link. Returns the SendByte email id.
 * A double-click within the same minute reuses one idempotency key, so it sends once.
 */
export async function sendDownloadEmail({ name, email, link, days, now = Date.now() }) {
  if (!hasEmail()) throw new Error('Email sending is not configured.');
  const { subject, html, text } = downloadEmail({ name, link, days });
  const minute = Math.floor(now / 60000);
  const idempotencyKey = 'dl-' + crypto.createHash('sha256').update(`${email}|${minute}`).digest('hex').slice(0, 32);

  const res = await fetch(`${API()}/emails`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SENDBYTE_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      from: process.env.EMAIL_FROM,
      to: [email],
      subject,
      html,
      text,
      tags: ['download-link'],
      idempotency_key: idempotencyKey,
    }),
    signal: AbortSignal.timeout(10000),
  });
  const data = await res.json().catch(() => ({}));
  if (res.ok) return data.id || null;
  const code = data?.error?.code || '';
  // Same key, different link (a second click in the same minute): the first email already went out.
  if (res.status === 409 && code === 'idempotency_conflict') return null;
  const err = new Error(`SendByte ${res.status} ${code}: ${data?.error?.message || 'send failed'}`);
  err.code = code;
  err.requestId = res.headers.get('x-request-id');
  throw err;
}
