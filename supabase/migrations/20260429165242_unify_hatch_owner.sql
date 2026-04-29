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
-- Migration order matters: the prior migration
-- (`…relax_name_ownership_for_bot.sql`) replaces the trigger
-- with a version that short-circuits to `RETURN NEW` whenever
-- `NEW.owner = hatch_bot_owner()`. With that in place, this
-- UPDATE — which sets `owner` to exactly that value for every
-- `@hatch:*` row — passes the trigger by construction. No
-- session-level GUC dance, no superuser escape hatch.
--
-- Pre-req: insert the bot UUID into `hatch_config` first
-- (the `…hatch_config_table.sql` migration adds the table;
-- this one assumes it's populated):
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

  -- The relaxed `enforce_name_ownership` trigger (deployed by
  -- the prior migration) short-circuits to `RETURN NEW` when
  -- `NEW.owner = hatch_bot_owner()`. Since we're setting `owner`
  -- to exactly that, the trigger lets every row through.
  UPDATE packages
     SET owner = bot_owner
   WHERE name LIKE '@hatch:%'
     AND owner IS DISTINCT FROM bot_owner;

  GET DIAGNOSTICS affected = ROW_COUNT;

  RAISE NOTICE 'reassigned % @hatch:* rows to %', affected, bot_owner;
END $$;
