// Supabase's HTTPS API (PostgREST) with the service_role key. Server-side only:
// the key bypasses row level security, so it must never reach the browser.
//   SUPABASE_URL               https://<project>.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY  service_role key (Project Settings → API keys)

const env = () => ({
  url: (process.env.SUPABASE_URL || '').replace(/\/+$/, ''),
  key: process.env.SUPABASE_SERVICE_ROLE_KEY || '',
});

export function configured() {
  const { url, key } = env();
  return Boolean(url && key);
}

async function call(method, path, { body, prefer } = {}) {
  const { url, key } = env();
  const res = await fetch(`${url}/rest/v1/${path}`, {
    method,
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
      ...(prefer ? { Prefer: prefer } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(10000),
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!res.ok) {
    const err = new Error(`Supabase ${res.status}: ${data?.message || text || res.statusText}`);
    err.status = res.status;
    err.code = data?.code;
    throw err;
  }
  return { data, res };
}

const enc = encodeURIComponent;

/** Inserts or refreshes a sign-up (one row per email). Returns the stored row. */
export async function saveSignup({ name, email, updates, country, userAgent }) {
  const fields = {
    name,
    wants_updates: Boolean(updates),
    country: country || null,
    user_agent: userAgent || null,
  };
  const columns = 'id,email,name,wants_updates,signup_count';
  try {
    const { data } = await call('POST', `signups?select=${columns}`, {
      body: { email, ...fields },
      prefer: 'return=representation',
    });
    return data[0];
  } catch (error) {
    if (error.code !== '23505') throw error; // not "email already exists"
  }
  // Already signed up: refresh the details and count the repeat.
  const { data: found } = await call('GET', `signups?email=eq.${enc(email)}&select=signup_count`);
  const { data } = await call('PATCH', `signups?email=eq.${enc(email)}&select=${columns}`, {
    body: { ...fields, signup_count: (found?.[0]?.signup_count || 1) + 1, updated_at: new Date().toISOString() },
    prefer: 'return=representation',
  });
  return data[0];
}

export async function markEmailSent(email, messageId) {
  await call('PATCH', `signups?email=eq.${enc(email)}`, {
    body: { last_email_id: messageId || null, last_emailed_at: new Date().toISOString() },
    prefer: 'return=minimal',
  });
}

export async function logDownload({ email, country, userAgent }) {
  await call('POST', 'downloads', {
    body: { email, country: country || null, user_agent: userAgent || null },
    prefer: 'return=minimal',
  });
}

async function count(table) {
  const { res } = await call('GET', `${table}?select=id&limit=1`, { prefer: 'count=exact' });
  const total = Number((res.headers.get('content-range') || '').split('/')[1]);
  return Number.isFinite(total) ? total : 0;
}

export async function counts() {
  const [signups, downloads] = await Promise.all([count('signups'), count('downloads')]);
  return { signups, downloads };
}
