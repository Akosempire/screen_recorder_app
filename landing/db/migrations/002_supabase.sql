-- Track the download-link email sent through SendByte.
ALTER TABLE signups ADD COLUMN IF NOT EXISTS last_email_id   text;
ALTER TABLE signups ADD COLUMN IF NOT EXISTS last_emailed_at timestamptz;

-- Supabase exposes the public schema through its REST API. Turning on row level
-- security with no policies means the anon and authenticated API roles can't
-- read or write these tables; only the website's server (the postgres role) can.
ALTER TABLE signups   ENABLE ROW LEVEL SECURITY;
ALTER TABLE downloads ENABLE ROW LEVEL SECURITY;
