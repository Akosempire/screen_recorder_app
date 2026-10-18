# Landing page (Vercel) with emailed download links

Visitors enter their name and email. The site saves them to a Google Sheet and
emails a download link from your Gmail. The link is signed and works for 7 days;
opening it records a "downloaded" row and starts the installer download from
GitHub Releases.

```
landing/
  index.html                  the page
  assets/                     screenshots, icon, self-hosted fonts
  api/signup.js               POST: save sign-up + send link
  api/download.js             GET:  check link, log, redirect to installer
  lib/token.js                signed link helpers
  google-apps-script/Code.gs  paste into your Google Sheet
  test/flow.test.js           `npm test`
```

## 1. Google Sheet + Apps Script (about 5 minutes)

1. Create a new Google Sheet (any name).
2. **Extensions → Apps Script**. Replace everything in `Code.gs` with
   [`google-apps-script/Code.gs`](google-apps-script/Code.gs). Save.
3. **Project Settings (gear) → Script properties → Add script property**:
   `SECRET` = a long random string. Keep it; Vercel needs the same value.
4. Back in the editor, pick the `authorize` function and click **Run**.
   Approve the permissions (Sheets + send email as you).
5. **Deploy → New deployment → type: Web app**.
   *Execute as:* **Me**. *Who has access:* **Anyone**. Click **Deploy** and
   copy the **Web app URL** (ends in `/exec`).

Rows appear in a `Sign-ups` tab: Time, Event (signed up / downloaded), Name,
Email, Wants updates, Country, Browser.

Gmail sending limit: about 100 emails a day on a free Google account
(1,500 on Google Workspace).

## 2. Vercel

1. **Add New → Project → Import** `screen_recorder_app`.
2. **Root Directory:** `landing`. Framework preset: **Other**. Vercel runs
   `npm run build`, which only checks that the functions load.
3. **Environment Variables**:

| Name | Value |
| --- | --- |
| `APPS_SCRIPT_URL` | the Web app URL from step 1.5 |
| `APPS_SCRIPT_SECRET` | the same `SECRET` as step 1.3 |
| `LINK_SECRET` | a different long random string (signs download links) |
| `DATABASE_URL` | Neon pooled connection string (see step 3) |
| `PUBLIC_URL` | optional, e.g. `https://yourdomain.com` once you add a domain |
| `INSTALLER_URL` | optional; defaults to the latest GitHub release |

4. **Deploy.** Then sign up on your page with your own email to check the
   whole flow.

## 3. Neon Postgres

Sign-ups and downloads are stored in Postgres on Neon (project
`muddy-glade-60136833`, branch `production`; see `neon.ts` and `.neon`). The
Sheet still gets a copy and still sends the email.

```bash
cd landing
npm install
npm i -g neon@latest
neon init -y --org-id org-silent-wind-63080554 --project-id muddy-glade-60136833 --branch production --services postgres
neon deploy            # signs in, provisions, writes DATABASE_URL(_UNPOOLED) to .env.local
npm run db:migrate     # creates the signups and downloads tables (uses the direct URL)
npm run build
npm start              # http://localhost:3000, uses .env.local
curl localhost:3000/api/health
```

Then copy `DATABASE_URL` (the pooled one, host ending in `-pooler`) into
Vercel's environment variables and redeploy. `/api/health` returns
`{"ok":true,"database":{"connected":true,...}}` when it's working.

- Driver: `pg` with `attachDatabasePool` from `@vercel/functions`, as Neon
  recommends for Vercel functions.
- Schema changes go in `db/migrations/NNN_name.sql`; run `npm run db:migrate`.
- If `DATABASE_URL` is not set, the site still works with the Sheet alone.
- `TEST_DATABASE_URL=… npm test` also runs the database test.

## Notes

- The installer itself is served from GitHub Releases, so the latest build is
  always what people get.
- The gate stops casual downloads. Someone who already has the link (or finds
  the GitHub release) can still download it.
- Changing `LINK_SECRET` invalidates every link already emailed.
