-- Add manifest-driven homepage + readme to the packages catalog.
--
-- Until this lands, `hatch publish` (and the bulk `hatch publish-all`)
-- strip both fields from the upsert payload — see the matching `None`
-- override in `src/bin/hatch.rs::publish_workspace`. After the
-- migration is applied to the live Supabase project, that override
-- can be removed so the manifest's `homepage` / `readme` round-trip
-- through to the catalog and out to the docs renderer.
--
-- Both columns are optional: legacy rows pre-dating the schema bump
-- have NULL here, and the consumer falls back to `git` (homepage)
-- or to a conventional `README.md` path (readme).

alter table public.packages
  add column if not exists homepage text,
  add column if not exists readme   text;

-- PostgREST caches the column set; nudge it so the next request
-- after the migration sees the new shape without waiting for the
-- automatic refresh.
notify pgrst, 'reload schema';
