// Brevo (brevo.com) transactional email over its HTTPS API, so it works from
// Vercel without an SMTP connection. Needs an API key (xkeysib-…) and a sender
// address verified in Brevo → Senders, Domains & Dedicated IPs.
const API = 'https://api.brevo.com/v3';

export const BREVO_KEY_RE = /^xkeysib-[A-Za-z0-9-]{20,}$/;

function brevoError(status, body) {
  const said = String(body?.message || body?.code || '').trim();
  const s = said.toLowerCase();
  let message;
  if (s.includes('ip address') || s.includes('unrecognised ip') || s.includes('unrecognized ip')) {
    message = 'Brevo blocked the website\'s server address. In Brevo → Security → Authorised IPs, turn off "Block unknown IP addresses" (Vercel\'s addresses change).';
  } else if (status === 401) {
    message = 'Brevo refused the API key. Create a new one in Brevo → SMTP & API → API keys and paste it again.';
  } else if (s.includes('sender') || s.includes('not valid') && s.includes('from')) {
    message = 'Brevo doesn\'t accept that sender address yet. Add and verify it in Brevo → Senders, Domains & Dedicated IPs.';
  } else if (s.includes('not activated') || s.includes('account')) {
    message = 'Your Brevo account can\'t send yet (Brevo may still be reviewing it). Check the Brevo dashboard.';
  } else {
    message = `Brevo could not send the email (error ${status}).`;
  }
  if (said && !message.includes(said)) message += ` (Brevo said: ${said})`;
  return Object.assign(new Error(message), { status: 400, brevoStatus: status });
}

async function call(apiKey, method, path, body, fetcher) {
  const res = await fetcher(`${API}${path}`, {
    method,
    headers: { 'api-key': apiKey, accept: 'application/json', 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(10000),
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = { message: text.slice(0, 200) }; }
  if (!res.ok) {
    console.error('Brevo', method, path, res.status, data?.code, data?.message);
    throw brevoError(res.status, data);
  }
  return data;
}

/** Sends one email. `config` is the loaded settings (BREVO_API_KEY, EMAIL_FROM, EMAIL_FROM_NAME). */
export async function sendEmail(config, { to, subject, html, text }, fetcher = fetch) {
  if (!config.BREVO_API_KEY || !config.EMAIL_FROM) {
    throw Object.assign(new Error('Email is not set up: add the Brevo API key and sender address in Settings.'), { status: 400 });
  }
  return call(config.BREVO_API_KEY, 'POST', '/smtp/email', {
    sender: { email: config.EMAIL_FROM, name: config.EMAIL_FROM_NAME || 'Screen Recorder' },
    to: [{ email: to }],
    subject,
    htmlContent: html,
    textContent: text,
  }, fetcher);
}

export const brevoReady = (config) => Boolean(config.BREVO_API_KEY && config.EMAIL_FROM);

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

export function codeEmail(code) {
  const html =
    '<div style="font-family:Segoe UI,Arial,sans-serif;color:#15171A;max-width:440px;line-height:1.55">' +
    '<h2 style="margin:0 0 12px">Screen Recorder</h2>' +
    '<p>Your sign-in code:</p>' +
    `<p style="font-size:30px;font-weight:700;letter-spacing:6px;margin:8px 0 16px">${esc(code)}</p>` +
    '<p>It works for 10 minutes and only once.</p>' +
    '<p style="color:#888;font-size:12px">If you didn\'t ask for this, you can ignore this email.</p></div>';
  return {
    subject: `${code} is your Screen Recorder sign-in code`,
    html,
    text: `Your Screen Recorder sign-in code: ${code}\n\nIt works for 10 minutes and only once.`,
  };
}
