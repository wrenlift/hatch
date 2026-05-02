-- Add readme_url to public.packages, mirror of docs_url.
--
-- `hatch publish` uploads each package's README.md to the
-- `package-readmes` bucket (sibling of `package-docs`) and
-- writes the public URL here. The site's readme route fetches
-- via this URL — same shape regardless of forge, so non-GitHub
-- hosts (GitLab / Bitbucket / Codeberg / self-hosted Forgejo)
-- get parity instead of empty placeholders.
--
-- Nullable: legacy rows without a populated readme_url fall
-- back to the existing `gitRawBase_` resolution path on the
-- site side.

alter table public.packages
  add column if not exists readme_url text;

-- Public-read bucket. Service role is the only path that
-- writes; everyone else reads via the public URL.
insert into storage.buckets (id, name, public)
values ('package-readmes', 'package-readmes', true)
on conflict (id) do update set public = true;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename  = 'objects'
      and policyname = 'package-readmes read'
  ) then
    create policy "package-readmes read"
      on storage.objects for select
      using (bucket_id = 'package-readmes');
  end if;
end $$;

notify pgrst, 'reload schema';
