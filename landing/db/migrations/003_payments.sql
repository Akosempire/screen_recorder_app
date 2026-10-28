-- Pro payments through Bachs. Run once in Supabase → SQL Editor.

-- One row per paid licence. The key is what the app stores and checks.
CREATE TABLE IF NOT EXISTS licenses (
  id                    bigserial PRIMARY KEY,
  license_key           text        NOT NULL UNIQUE,
  email                 text        NOT NULL,
  name                  text,
  plan                  text        NOT NULL CHECK (plan IN ('monthly', 'lifetime')),
  status                text        NOT NULL DEFAULT 'active',
  currency              text,
  current_period_end    timestamptz,
  bachs_customer_id     text,
  bachs_subscription_id text UNIQUE,
  bachs_checkout_id     text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS licenses_email_idx ON licenses (lower(email));

-- One row per "Upgrade" click. `activation` is a long random id the app (or
-- the website) creates and later uses to collect its licence key.
CREATE TABLE IF NOT EXISTS checkouts (
  activation        text        PRIMARY KEY,
  email             text        NOT NULL,
  name              text,
  plan              text        NOT NULL CHECK (plan IN ('monthly', 'lifetime')),
  currency          text        NOT NULL CHECK (currency IN ('NGN', 'USD')),
  bachs_checkout_id text,
  checkout_url      text,
  license_key       text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- Bachs webhook events already handled (Bachs may deliver one more than once).
CREATE TABLE IF NOT EXISTS webhook_events (
  id         text        PRIMARY KEY,
  type       text        NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Small key/value store (the Bachs product ids, created automatically).
CREATE TABLE IF NOT EXISTS app_settings (
  key        text        PRIMARY KEY,
  value      text        NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Only the website's server (service_role) may read or write these.
ALTER TABLE licenses       ENABLE ROW LEVEL SECURITY;
ALTER TABLE checkouts      ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_settings   ENABLE ROW LEVEL SECURITY;
