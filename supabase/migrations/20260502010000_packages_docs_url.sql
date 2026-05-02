-- Add docs_url to public.packages.
--
-- Sibling of the homepage / readme columns added in 20260501.
-- Hatch publish populates this with the public Supabase Storage
-- URL of the package's `docs.json` artifact (uploaded by the
-- `/hatch-bot/docs-upload` Edge Function during the publish
-- flow). The site's `lib/api.wren` fetches from this URL at
-- request time instead of pre-rendering the JSON at image build.
--
-- Nullable so legacy rows pre-dating the upload pipeline keep
-- working — the docs renderer falls back to the empty placeholder
-- when the column is null.

alter table public.packages
  add column if not exists docs_url text;

-- Storage bucket the upload endpoint writes to. Public read so
-- consumers (the site, eventually editor / IDE plugins) can curl
-- the JSON without auth.
insert into storage.buckets (id, name, public)
values ('package-docs', 'package-docs', true)
on conflict (id) do update set public = true;

-- Service role writes; everyone else reads only via the public
-- URL. The hatch-bot Edge Function has the service role and is
-- the only path that uploads docs JSON.
do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename  = 'objects'
      and policyname = 'package-docs read'
  ) then
    create policy "package-docs read"
      on storage.objects for select
      using (bucket_id = 'package-docs');
  end if;
end $$;

-- PostgREST caches the column set; nudge it so the next request
-- after the migration sees the new shape.
notify pgrst, 'reload schema';
