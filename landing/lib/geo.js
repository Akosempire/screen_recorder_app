// Which currency to show a visitor. Vercel adds the visitor's country (from
// their IP address) to every request as `x-vercel-ip-country`. Nigeria pays in
// naira; everyone else sees dollars. People can still switch by hand.
const NAIRA_COUNTRIES = new Set(['NG']);

export function countryOf(req) {
  const raw = String((req && req.headers && (req.headers['x-vercel-ip-country'] || req.headers['cf-ipcountry'])) || '')
    .trim().toUpperCase();
  return /^[A-Z]{2}$/.test(raw) && raw !== 'XX' ? raw : null;
}

export function currencyFor(country) {
  return country && NAIRA_COUNTRIES.has(country) ? 'NGN' : 'USD';
}
