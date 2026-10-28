// Small helpers for Vercel Node functions.

/** The request body as raw bytes (needed to verify webhook signatures). */
export async function readRaw(req) {
  if (Buffer.isBuffer(req.rawBody)) return new Uint8Array(req.rawBody);
  const chunks = [];
  for await (const chunk of req) chunks.push(typeof chunk === 'string' ? Buffer.from(chunk) : chunk);
  return new Uint8Array(Buffer.concat(chunks));
}

/** JSON body, whether or not the platform already parsed it. */
export async function readJson(req) {
  let body = req.body;
  if (body === undefined) {
    const raw = Buffer.from(await readRaw(req)).toString('utf8');
    try { body = raw ? JSON.parse(raw) : {}; } catch { body = {}; }
  } else if (typeof body === 'string') {
    try { body = JSON.parse(body); } catch { body = {}; }
  }
  return body && typeof body === 'object' ? body : {};
}

/** Sends a BillingError's message, or a generic one for unexpected errors. */
export function sendError(res, error, fallback) {
  const status = Number.isInteger(error?.status) && error.status >= 400 && error.status < 600 ? error.status : 500;
  if (status >= 500) console.error(fallback, error?.message, error?.statusCode, error?.errorCode);
  const message = status < 500 && error?.message ? error.message : fallback;
  return res.status(status).json({ error: message });
}
