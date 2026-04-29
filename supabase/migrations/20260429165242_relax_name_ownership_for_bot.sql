-- Patch `enforce_name_ownership` so writes whose `NEW.owner`
-- already points at the canonical bot UUID always pass —
-- regardless of what the row's previous owner was.
--
-- The trigger guards `@user:*`-style packages from being
-- squatted across developer accounts: the first writer's UUID
-- is the only legitimate updater. For the official `@hatch:*`
-- namespace the policy is different — the hatch-bot service
-- account is the canonical (and only) legitimate writer, with
-- CI as the publish path. Without this short-circuit, any
-- `@hatch:*` row whose first publish landed under a developer's
-- UUID (the old PostgREST publish flow) blocks subsequent CI
-- updates with
--
--   error: package @hatch:window is owned by a different user
--
-- Pairs with `20260429165241_unify_hatch_owner.sql`: the prior
-- migration restamps existing rows; this one prevents the same
-- failure mode from re-emerging if a row ever gets stamped to a
-- non-bot owner later.

CREATE OR REPLACE FUNCTION enforce_name_ownership()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  bot_owner uuid := hatch_bot_owner();
  existing  uuid;
BEGIN
  -- The hatch-bot service account is the canonical publisher
  -- for every official `@hatch:*` row. Any write whose `owner`
  -- field already points at the bot is implicitly trusted (the
  -- only path that produces such writes is CI, which already
  -- authenticates via `HATCH_BOT_SECRET`).
  IF bot_owner IS NOT NULL AND NEW.owner IS NOT DISTINCT FROM bot_owner THEN
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
