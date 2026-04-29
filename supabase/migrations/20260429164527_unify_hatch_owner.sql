-- Unify ownership of every `@hatch:*` package row under a single
-- canonical owner (the hatch-bot service account).
--
-- Why
-- ---
-- The publish workflow stamps a row's `owner` to whatever the bot
-- function fills in (`HATCH_BOT_OWNER_UUID`). Earlier ad-hoc
-- publishes ran under individual developer accounts, so the older
-- rows for `@hatch:window`, `@hatch:gpu`, …  are owned by a mix of
-- UUIDs. The publish path's ownership-mismatch trigger then
-- rejects bot-driven updates to those rows:
--
--   error: package @hatch:window is owned by a different user
--
-- Forcing every official `@hatch:*` row to belong to the bot
-- account makes CI publishes idempotent and removes the per-package
-- "first publish wins ownership" race that the trigger was guarding
-- against.
--
-- This migration is written so it's safe to run once or repeatedly:
-- the UPDATE only touches rows whose owner doesn't already match
-- the target UUID.
--
-- One-time prep: set the canonical bot UUID as a database GUC so
-- the UPDATE doesn't have to inline the literal. Run this in the
-- SQL editor (or via psql) BEFORE applying the migration:
--
--   ALTER DATABASE postgres
--     SET app.hatch_bot_owner = '00000000-0000-0000-0000-000000000000';
--
-- Replace the UUID with the value of the `HATCH_BOT_OWNER_UUID`
-- secret on the hatch-bot Edge Function (`supabase secrets list`
-- shows the digest, the dashboard shows the value). The setting is
-- per-database; subsequent migrations / functions can read it via
-- `current_setting('app.hatch_bot_owner')`.

DO $$
DECLARE
  bot_owner uuid := current_setting('app.hatch_bot_owner', true)::uuid;
  affected  int;
BEGIN
  IF bot_owner IS NULL THEN
    RAISE EXCEPTION 'app.hatch_bot_owner is not set on this database. '
      'Run `ALTER DATABASE postgres SET app.hatch_bot_owner = ''<uuid>'';` '
      'with the hatch-bot owner UUID before applying this migration.';
  END IF;

  -- The `enforce_name_ownership` trigger raises P0001 on any
  -- update that doesn't match the existing owner, which would
  -- block this very migration. Switch to replica mode for the
  -- transaction so user-defined triggers don't fire — the
  -- whole point of this migration is to *re-stamp* ownership,
  -- and the trigger's invariant is going to be true again the
  -- moment we finish.
  PERFORM set_config('session_replication_role', 'replica', true);

  UPDATE packages
     SET owner = bot_owner
   WHERE name LIKE '@hatch:%'
     AND owner IS DISTINCT FROM bot_owner;

  GET DIAGNOSTICS affected = ROW_COUNT;

  PERFORM set_config('session_replication_role', 'origin', true);

  RAISE NOTICE 'reassigned % @hatch:* rows to %', affected, bot_owner;
END $$;
