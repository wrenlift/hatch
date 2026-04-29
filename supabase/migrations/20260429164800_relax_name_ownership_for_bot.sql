-- Relax `enforce_name_ownership` so the hatch-bot account can
-- publish any `@hatch:*` row without tripping the ownership
-- check.
--
-- Why
-- ---
-- The trigger guards against package-name squatting between
-- developers — `@my:cool-thing` should be writable only by the
-- account that first claimed it. For *official* `@hatch:*`
-- packages the policy is different: the bot service account is
-- the only legitimate writer (CI is the canonical publish path,
-- developer accounts publishing under their personal UUID is
-- the exception). Without this exemption the bot can't update a
-- row whose original publish landed under a developer's UUID,
-- and we hit
--
--   error: package @hatch:window is owned by a different user
--
-- on every release retry.
--
-- The fix slots a `NEW.owner = <bot uuid>` short-circuit at the
-- top of the trigger so the existing per-name ownership invariant
-- still applies to user-namespaced packages, while bot-driven
-- writes (whether updates to an existing row or fresh inserts)
-- always pass.
--
-- Pairs with `20260429164527_unify_hatch_owner.sql` — the prior
-- migration restamped existing rows; this one prevents the same
-- failure mode from re-emerging.

DO $$
DECLARE
  bot_owner uuid := current_setting('app.hatch_bot_owner', true)::uuid;
BEGIN
  IF bot_owner IS NULL THEN
    RAISE EXCEPTION 'app.hatch_bot_owner is not set on this database. '
      'Run `ALTER DATABASE postgres SET app.hatch_bot_owner = ''<uuid>'';` '
      'with the hatch-bot owner UUID before applying this migration.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION enforce_name_ownership()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  bot_owner uuid := current_setting('app.hatch_bot_owner', true)::uuid;
  existing  uuid;
BEGIN
  -- The hatch-bot service account is the canonical publisher
  -- for every official @hatch:* row. Any write whose `owner`
  -- field already points at the bot is implicitly trusted
  -- (the only path that produces such writes is CI, which
  -- already authenticates via `HATCH_BOT_SECRET`).
  IF NEW.owner IS NOT DISTINCT FROM bot_owner THEN
    RETURN NEW;
  END IF;

  -- For non-bot writes, fall back to the original invariant:
  -- the package name's owner cannot change between writes.
  -- A first write (no existing row) is allowed; a subsequent
  -- write under a different UUID is rejected.
  SELECT owner INTO existing
    FROM packages
   WHERE name = NEW.name
   LIMIT 1;

  IF existing IS NOT NULL AND existing IS DISTINCT FROM NEW.owner THEN
    RAISE EXCEPTION 'package % is owned by a different user', NEW.name;
  END IF;

  RETURN NEW;
END;
$$;
