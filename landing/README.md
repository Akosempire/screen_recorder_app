# Landing page (Vercel + Supabase + SendByte)

Visitors enter their name and email in the Download pop-up. The site saves
them to **Supabase** (Postgres) and emails a download link through
**SendByte**. The link is signed and works for 7 days; opening it records a
download in Supabase and starts the installer download from GitHub Releases.

```
landing/
  index.html                 the page
  assets/                    screenshots, icon, self-hosted fonts
  api/signup.js              POST: save sign-up to Supabase, email the link
  api/download.js            GET:  check link, log download, redirect to installer
  api/health.js              GET:  database connected? (counts only)
  lib/db.js                  Postgres pool (pg + attachDatabasePool)
  lib/email.js               SendByte download-link email
  lib/token.js               signed link helpers
  db/migrations/*.sql        schema; `npm run db:migrate`
  scripts/                   build, local server, migrations
  test/flow.test.js          `npm test`
```

## 1. Supabase (through Vercel)

1. Vercel project → **Storage** → **Create Database** → **Supabase**. Create a
   project (region near your users, e.g. Frankfurt or London) and connect it
   to this project for all environments. Vercel adds `POSTGRES_URL`,
   `POSTGRES_URL_NON_POOLING`, `SUPABASE_URL` and the keys by itself.
2. Create the tables, once. Either:
   - **Supabase dashboard → SQL Editor**: run `db/migrations/001_signups.sql`,
     then `db/migrations/002_supabase.sql`; or
   - locally: `vercel env pull .env.local`, then `npm run db:migrate`.

Row level security is on with no policies, so Supabase's public API keys
can't read or write these tables. Only the website's server can. Browse the
data in **Supabase → Table Editor** (`signups`, `downloads`).

## 2. SendByte

1. In the SendByte dashboard, add and verify your sending domain (publish the
   SPF, DKIM and DMARC records it gives you; the domain must show *verified*).
2. Create a **live** API key (`sk_live_…`). A sandbox key (`sk_test_…`)
   never delivers to real inboxes.

## 3. Vercel environment variables

| Name | Value |
| --- | --- |
| `SUPABASE_URL` | `https://<project-ref>.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase → Project Settings → API keys → `service_role` (server only, never in the page) |
| `POSTGRES_URL` | optional alternative: the pooled connection string (port 6543); used only when the two above are not set |
| `SENDBYTE_API_KEY` | your SendByte live key |
| `EMAIL_FROM` | e.g. `Screen Recorder <downloads@yourdomain.com>` (a verified domain) |
| `LINK_SECRET` | a long random string (signs download links) |
| `PUBLIC_URL` | optional, e.g. `https://yourdomain.com` once you add a domain |
| `INSTALLER_URL` | optional; defaults to the latest GitHub release |

Project settings: **Root Directory** `landing`, framework **Other**. Vercel
runs `npm run build`, which checks the functions load and copies the page to
`public/`. Redeploy after changing variables, then:

- `https://<site>/api/health` → `{"ok":true,"database":{"connected":true,...}}`
- sign up with your own email and open the link you receive.

If anything is missing, the form answers "The site is not set up yet" and the
function log says which setting is missing.

## Local development

```bash
cd landing
npm install
vercel env pull .env.local   # or write POSTGRES_URL etc. by hand
npm run db:migrate
npm start                    # http://localhost:3000
TEST_DATABASE_URL=postgres://... npm test   # full flow against a real Postgres
```

## Notes

- Database access: Supabase's HTTPS API with the service_role key
  (`lib/supabase-rest.js`) when `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`
  are set; otherwise `pg` with `attachDatabasePool` on `POSTGRES_URL`.
  With `pg` on Supabase's pooled connection, Supabase uses its own TLS certificate
  authority, so the connection is encrypted without CA verification
  (`lib/db.js`).
- Double clicks within a minute send one email (SendByte idempotency key).
- The installer is served from GitHub Releases, so the latest build is always
  what people get. Someone who finds the release page can still download it
  directly; the gate stops casual downloads.
- Changing `LINK_SECRET` invalidates every link already emailed.
