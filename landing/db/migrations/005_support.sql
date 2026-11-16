-- Help requests from the app ("Get help"). Run once in Supabase → SQL Editor
-- (after 004_admin.sql). Until it's run, requests still reach the dashboard's
-- Activity tab (shortened) and the admin inbox (if email is set up).
CREATE TABLE IF NOT EXISTS support_requests (
  id          bigserial   PRIMARY KEY,
  created_at  timestamptz NOT NULL DEFAULT now(),
  kind        text        NOT NULL DEFAULT 'problem',   -- problem | question | idea
  message     text        NOT NULL,
  email       text,
  source      text,                                     -- app | extension | website
  app_version text,
  os          text,
  details     text,                                     -- app details + recent log, if the user agreed
  country     text,
  status      text        NOT NULL DEFAULT 'open',      -- open | done
  updated_at  timestamptz
);
CREATE INDEX IF NOT EXISTS support_requests_created_idx ON support_requests (created_at DESC);
ALTER TABLE support_requests ENABLE ROW LEVEL SECURITY;
