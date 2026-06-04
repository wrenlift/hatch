-- Add changelog_url to public.packages, mirror of readme_url.
--
-- `hatch publish` uploads each package's CHANGELOG.md to the
-- `package-changelogs` bucket (sibling of `package-readmes`)
-- and writes the public URL here. The site's changelog route
-- fetches via this URL — same shape regardless of forge.
--
-- Nullable: legacy rows without a populated changelog_url fall
-- back to the `gitRawBase_` resolution path on the site side
-- (which serves the `<git-raw>/CHANGELOG.md` URL when the
-- forge is GitHub).

alter table public.packages
  add column if not exists changelog_url text;

-- Public-read bucket. Service role is the only path that
-- writes; everyone else reads via the public URL. Same shape
-- as `package-readmes` (see 20260502020000_packages_readme_url.sql).
insert into storage.buckets (id, name, public)
values ('package-changelogs', 'package-changelogs', true)
on conflict (id) do update set public = true;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename  = 'objects'
      and policyname = 'package-changelogs read'
  ) then
    create policy "package-changelogs read"
      on storage.objects for select
      using (bucket_id = 'package-changelogs');
  end if;
end $$;

notify pgrst, 'reload schema';
