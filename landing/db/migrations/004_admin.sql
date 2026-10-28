-- Admin dashboard. Run once in Supabase → SQL Editor (after 003_payments.sql).

-- Every successful payment (first payments and renewals), for sales totals.
CREATE TABLE IF NOT EXISTS payments (
  id           text        PRIMARY KEY,          -- Bachs charge / event id
  license_key  text,
  email        text,
  plan         text,
  currency     text,
  amount       numeric(14, 2),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS payments_created_idx ON payments (created_at DESC);

-- What admins did (sign-ins, settings changes, licences granted/revoked).
CREATE TABLE IF NOT EXISTS admin_log (
  id         bigserial   PRIMARY KEY,
  email      text        NOT NULL,
  action     text        NOT NULL,
  detail     text,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE licenses  ADD COLUMN IF NOT EXISTS note       text;
ALTER TABLE licenses  ADD COLUMN IF NOT EXISTS revoked_at timestamptz;
ALTER TABLE downloads ADD COLUMN IF NOT EXISTS os         text;

ALTER TABLE payments  ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_log ENABLE ROW LEVEL SECURITY;
