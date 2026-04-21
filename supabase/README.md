# hatch-bot

Supabase Edge Function that owns the `hatch publish` write path.
Replaces the direct PostgREST `/rest/v1/packages` call that stopped
working when Supabase deprecated the legacy HS256 `JWT Secret` +
service_role key flow.

## Endpoints

| path | method | purpose |
| --- | --- | --- |
| `GET  /hatch-bot/` | health | returns `{ ok: true, service: "hatch-bot", ts: "…" }` — handy for `curl` smoke tests |
| `POST /hatch-bot/publish` | publish | upserts a package row; body matches the Rust `PackageRecord` shape |

Auth is a single shared bearer token (`HATCH_BOT_SECRET`) set as
a function secret. No JWTs, no key-type negotiation, no provider
integration — just a string CI and the function agree on.

## One-time setup

1. **Install the Supabase CLI** — `brew install supabase/tap/supabase`
   (or whichever method your platform uses).

2. **Link this directory to your Supabase project.** From the
   repo root:
   ```sh
   supabase login
   supabase link --project-ref <project-ref>
   ```
   The project-ref is in the dashboard URL: `supabase.com/dashboard/project/<ref>`.
   `supabase link` writes the ref into `supabase/config.toml`.

3. **Generate a shared secret** for CI and the function:
   ```sh
   openssl rand -hex 32
   ```
   You'll paste this value in two places next. Keep it somewhere
   safe — you can always rotate by repeating this step.

4. **Register the secret with the function.** From the repo root:
   ```sh
   supabase secrets set HATCH_BOT_SECRET=<the-hex-string>
   ```

5. **Register the same secret in GitHub** for the publish CI:
   - Repo → Settings → Secrets and variables → Actions
   - New repository secret named `HATCH_BOT_SECRET`, value = the same hex string
   - While you're there, add `HATCH_BOT_URL` (an Actions *variable*,
     not a secret — URL is harmless to expose):
     `https://<project-ref>.supabase.co/functions/v1/hatch-bot/publish`
     Note the trailing `/publish` — the CLI POSTs to this URL
     verbatim, it doesn't append any path of its own.

6. **Deploy the function:**
   ```sh
   supabase functions deploy hatch-bot
   ```
   The CLI uploads `supabase/functions/hatch-bot/index.ts` and
   the config from `supabase/config.toml`.

## Smoke test

```sh
# Health check — unauth'd, should 200.
curl https://<project-ref>.supabase.co/functions/v1/hatch-bot/

# Auth check — should 401 without the secret.
curl -X POST https://<project-ref>.supabase.co/functions/v1/hatch-bot/publish

# Real call (dry-run a harmless update to an existing row).
curl -X POST https://<project-ref>.supabase.co/functions/v1/hatch-bot/publish \
  -H "authorization: Bearer $HATCH_BOT_SECRET" \
  -H "content-type: application/json" \
  -d '{"name":"@hatch:test","version":"0.0.0","git":"https://example.invalid"}'
```

## Rotating the secret

1. `openssl rand -hex 32` → new value
2. `supabase secrets set HATCH_BOT_SECRET=<new>`
3. GitHub → update the `HATCH_BOT_SECRET` secret

Both places have to match for CI publishes to keep working. The
function starts honoring the new value within a few seconds of
step 2 (no redeploy needed — Supabase hot-reloads env secrets).

## Iterating on the function

Local dev loop:

```sh
supabase functions serve hatch-bot --env-file .env.local
# in another terminal:
curl -X POST http://localhost:54321/functions/v1/hatch-bot/publish \
  -H "authorization: Bearer $(cat .env.local | grep HATCH_BOT_SECRET | cut -d= -f2)" \
  -H "content-type: application/json" \
  -d '{…}'
```

`.env.local` should be **gitignored**; drop your local
`HATCH_BOT_SECRET` in there.
