-- Restamp every `@hatch:*` row's `owner` to the canonical bot
-- UUID returned by `hatch_bot_owner()`.
--
-- The publish workflow stamps a row's `owner` to whatever the
-- bot function fills in (`HATCH_BOT_OWNER_UUID`). Earlier ad-hoc
-- publishes ran under individual developer accounts, so older
-- rows for `@hatch:window`, `@hatch:gpu`, … are owned by a mix
-- of UUIDs. The publish path's `enforce_name_ownership` trigger
-- rejects bot-driven updates to those rows:
--
--   error: package @hatch:window is owned by a different user
--
-- Forcing every official `@hatch:*` row to belong to the bot
-- account makes CI publishes idempotent.
--
-- Pre-req: insert the bot UUID into `hatch_config` first
-- (the `20260429165240_hatch_config_table.sql` migration adds
-- the table; this one assumes it's populated):
--
--   INSERT INTO hatch_config (key, value, note) VALUES
--     ('hatch_bot_owner', '<uuid>', 'bot service account')
--   ON CONFLICT (key) DO UPDATE SET value = excluded.value;

DO $$
DECLARE
  bot_owner uuid := hatch_bot_owner();
  affected  int;
BEGIN
  IF bot_owner IS NULL THEN
    RAISE EXCEPTION 'hatch_config has no `hatch_bot_owner` row. '
      'Insert it before applying this migration: '
      'INSERT INTO hatch_config (key, value) VALUES '
      '(''hatch_bot_owner'', ''<uuid>'') '
      'ON CONFLICT (key) DO UPDATE SET value = excluded.value;';
  END IF;

  -- The `enforce_name_ownership` trigger raises P0001 on any
  -- update that doesn't match the existing owner, which would
  -- block this very migration. Switch to replica mode for the
  -- transaction so user-defined triggers don't fire — the whole
  -- point of this migration is to *re-stamp* ownership, and the
  -- trigger's invariant is going to be true again the moment we
  -- finish.
  PERFORM set_config('session_replication_role', 'replica', true);

  UPDATE packages
     SET owner = bot_owner
   WHERE name LIKE '@hatch:%'
     AND owner IS DISTINCT FROM bot_owner;

  GET DIAGNOSTICS affected = ROW_COUNT;

  PERFORM set_config('session_replication_role', 'origin', true);

  RAISE NOTICE 'reassigned % @hatch:* rows to %', affected, bot_owner;
END $$;
