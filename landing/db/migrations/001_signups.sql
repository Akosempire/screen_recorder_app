-- Sign-ups from the landing page (one row per email) and every download.
CREATE TABLE IF NOT EXISTS signups (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email         text        NOT NULL UNIQUE,
  name          text        NOT NULL,
  wants_updates boolean     NOT NULL DEFAULT false,
  country       text,
  user_agent    text,
  signup_count  integer     NOT NULL DEFAULT 1,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS downloads (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  email       text        NOT NULL,
  country     text,
  user_agent  text,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS downloads_email_idx ON downloads (email);
CREATE INDEX IF NOT EXISTS downloads_created_at_idx ON downloads (created_at);
