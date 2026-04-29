-- A tiny key/value config table the rest of the schema can
-- reference without needing the dashboard role to set
-- database-level GUCs (Supabase's hosted Postgres rejects
-- `ALTER DATABASE postgres SET …` for non-superusers).
--
-- Single intended writer is the project admin via the SQL
-- editor; readers are the trigger functions in this `supabase/`
-- tree. The table is locked to one row per key so callers can
-- rely on the lookup helper returning at most one value.

CREATE TABLE IF NOT EXISTS hatch_config (
  key   text PRIMARY KEY,
  value text NOT NULL,
  note  text
);

-- Lock down direct writes — only superusers / service_role
-- should touch the table. The function below reads it.
ALTER TABLE hatch_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS hatch_config_no_one ON hatch_config;
CREATE POLICY hatch_config_no_one ON hatch_config
  FOR ALL TO public
  USING (false)
  WITH CHECK (false);

-- Convenience helper for callers that just need the bot UUID.
-- `SECURITY DEFINER` so the trigger / function callers don't
-- need direct read access on the table — the function owner
-- (postgres on hosted Supabase) supplies the access.
CREATE OR REPLACE FUNCTION hatch_bot_owner()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT value::uuid FROM hatch_config WHERE key = 'hatch_bot_owner'
$$;

COMMENT ON FUNCTION hatch_bot_owner() IS
  'Canonical hatch-bot service-account UUID — every `@hatch:*` row '
  'is expected to have `owner = hatch_bot_owner()` post-migration. '
  'Set the underlying value with: '
  'INSERT INTO hatch_config (key, value, note) VALUES '
  '(''hatch_bot_owner'', ''<uuid>'', ''bot service account'') '
  'ON CONFLICT (key) DO UPDATE SET value = excluded.value;';
