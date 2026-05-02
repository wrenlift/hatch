// hatch-bot — package publish + release-tag endpoint for hatch CLI / CI.
//
// This function replaces the direct PostgREST publish path.
// Supabase deprecated the legacy HS256 `JWT Secret` and moved
// service_role out of the API-key surface, so `hatch publish`
// couldn't authenticate against `/rest/v1/packages` cleanly
// from CI. The Edge Function owns both halves:
//
//   1. Auth — a single shared secret (`HATCH_BOT_SECRET`) that
//      CI presents via `Authorization: Bearer <secret>`. No JWT
//      math, no key-type negotiation, no provider integration.
//
//   2. DB access — the function runs inside Supabase's trust
//      boundary and reaches Postgres via the service client.
//      RLS and the public/anon/secret key churn happen one
//      layer away.
//
// Endpoints
// ---------
//
// `POST /publish` — body shape (JSON) mirrors `PackageRecord`:
//
//   { "name": "@hatch:foo", "version": "1.2.3",
//     "git":  "https://github.com/…", "description": "...",
//     "owner": "<uuid>" }          ← optional
//
// `GET /proxy?url=<upstream>` — allowlisted CORS proxy for the
// browser playground. GitHub release-asset URLs don't carry CORS
// headers, so the playground can't `fetch()` them directly. This
// route fetches them server-side and re-emits with permissive
// CORS + a cross-origin CORP header (so a future COEP-locked
// page can also consume them). No bearer auth — the upstreams are
// already public; the allowlist is the security boundary against
// using the bot as a generic SSRF gadget.
//
// `POST /tag` — body shape:
//
//   { "tag": "publish/hatch-foo@1.2.3", "sha": "abc...",
//     "owner": "wrenlift", "repo": "hatch" }   ← owner/repo optional
//
// Creates a lightweight ref `refs/tags/<tag>` pointing at `<sha>`,
// using a GitHub App installation token minted from the App
// credentials in the function's env. Tag pushes done this way
// trigger downstream workflows (unlike pushes by the workflow's
// own GITHUB_TOKEN). owner/repo default to the hardcoded
// `wrenlift/hatch` since this function is project-specific;
// pass them in the body to override.
//
// owner is optional on /publish; when present it's stored verbatim
// so auditing / listing by publisher still works without a real
// Supabase user row behind the request.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { createAppAuth } from 'https://esm.sh/@octokit/auth-app@7'

interface PackageRecord {
  name: string
  version: string
  git: string
  description?: string
  homepage?: string
  readme?: string
  docs_url?: string
  owner?: string
}

function validate(body: unknown): { ok: true; record: PackageRecord } | { ok: false; reason: string } {
  if (typeof body !== 'object' || body === null) {
    return { ok: false, reason: 'body must be a JSON object' }
  }
  const b = body as Record<string, unknown>
  const need = (field: string): string | null =>
    typeof b[field] === 'string' && (b[field] as string).length > 0
      ? null
      : `'${field}' must be a non-empty string`
  for (const f of ['name', 'version', 'git'] as const) {
    const err = need(f)
    if (err) return { ok: false, reason: err }
  }
  for (const f of ['description', 'homepage', 'readme', 'docs_url', 'owner'] as const) {
    if (b[f] !== undefined && typeof b[f] !== 'string') {
      return { ok: false, reason: `'${f}' must be a string when present` }
    }
  }
  return { ok: true, record: b as PackageRecord }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

function text(msg: string, status = 200): Response {
  return new Response(msg, { status, headers: { 'content-type': 'text/plain' } })
}

// Shared bearer-auth gate. Returns null on success or the error
// `Response` to short-circuit with. Centralised so /publish and
// /tag use the same secret + the same envvar misconfig path.
function checkAuth(req: Request): Response | null {
  const expected = Deno.env.get('HATCH_BOT_SECRET')
  if (!expected) {
    console.error('HATCH_BOT_SECRET is not set in function environment')
    return text('server misconfigured', 500)
  }
  const auth = req.headers.get('authorization') ?? ''
  const presented = auth.startsWith('Bearer ') ? auth.slice(7) : ''
  if (presented !== expected) {
    return text('unauthorized', 401)
  }
  return null
}

async function handlePublish(req: Request): Promise<Response> {
  let body: unknown
  try {
    body = await req.json()
  } catch (_) {
    return text('invalid JSON body', 400)
  }
  const v = validate(body)
  if (!v.ok) return text(v.reason, 400)
  const record = v.record

  // `packages.owner` is NOT NULL. If the caller didn't provide
  // one (CI typically doesn't — no user identity behind the
  // bearer), stamp the configured bot UUID. Must be a row in
  // `auth.users` so any foreign keys on the column still resolve.
  if (record.owner === undefined) {
    const botOwner = Deno.env.get('HATCH_BOT_OWNER_UUID')
    if (!botOwner) {
      return text(
        "owner required: set HATCH_BOT_OWNER_UUID on the function " +
          "or include 'owner' in the request body",
        400,
      )
    }
    record.owner = botOwner
  }

  // --- DB write ------------------------------------------------
  // SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY are auto-injected
  // into every Edge Function by the Supabase runtime. This is
  // still the documented way to get admin DB access from inside
  // a function, even under the new API-keys model — the
  // deprecation was of exposing service_role to external
  // callers, not of the internal plumbing.
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !serviceKey) {
    console.error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing')
    return text('server misconfigured', 500)
  }
  const client = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  // Upsert on (name, version) so repeat publishes of the same
  // version refresh the row instead of erroring on the PK.
  const { error } = await client
    .from('packages')
    .upsert(record, { onConflict: 'name,version' })

  if (error) {
    console.error('upsert failed:', error)
    return json({ error: error.message ?? 'database error', details: error }, 500)
  }

  return json({ published: `${record.name}@${record.version}` })
}

// `POST /docs-upload` — body shape:
//
//   { "name": "@hatch:foo", "version": "1.2.3",
//     "docs": [ /* ModuleDoc[] from `hatch docs` */ ] }
//
// Uploads the JSON to the public `package-docs` bucket at
// `<short>/<version>/docs.json` (where `short` is `name` with
// the `@hatch:` prefix stripped and `:` / `/` / `@` replaced
// with `_` so storage object keys stay path-safe). Returns the
// canonical public URL the consumer should write back into
// `packages.docs_url`.
//
// Bound to the same `HATCH_BOT_SECRET` /publish + /tag use.
// `hatch publish` POSTs the JSON inline — no presigned-URL
// round-trip. Docs payloads are small (<1MB per package), so
// proxied upload is fine and avoids a second request.
async function handleDocsUpload(req: Request): Promise<Response> {
  let body: unknown
  try {
    body = await req.json()
  } catch (_) {
    return text('invalid JSON body', 400)
  }
  if (typeof body !== 'object' || body === null) {
    return text('body must be a JSON object', 400)
  }
  const b = body as Record<string, unknown>
  if (typeof b.name !== 'string' || !b.name) return text("'name' must be a non-empty string", 400)
  if (typeof b.version !== 'string' || !b.version) return text("'version' must be a non-empty string", 400)
  if (b.docs === undefined) return text("'docs' (array of ModuleDoc) is required", 400)

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !serviceKey) {
    console.error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing')
    return text('server misconfigured', 500)
  }
  const client = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  // Replace path-unfriendly characters in the name to derive the
  // object key. `@hatch:foo` → `hatch_foo`. URL-encoded `@` and
  // `:` would technically work too but stack badly with proxies.
  const short = b.name.replace(/^@hatch:/, '').replace(/[:@/]/g, '_')
  const key = `${short}/${b.version}/docs.json`
  const payload = new TextEncoder().encode(JSON.stringify(b.docs))

  const { error: upErr } = await client
    .storage
    .from('package-docs')
    .upload(key, payload, {
      contentType: 'application/json',
      upsert: true,
    })
  if (upErr) {
    console.error('storage upload failed:', upErr)
    return json({ error: upErr.message ?? 'storage error' }, 500)
  }

  const { data: pub } = client.storage.from('package-docs').getPublicUrl(key)
  return json({ url: pub.publicUrl, key })
}

// `POST /readme-upload` — body shape:
//
//   { "name": "@hatch:foo", "version": "1.2.3", "readme": "<markdown>" }
//
// Uploads the markdown text to the public `package-readmes`
// bucket at `<short>/<version>/README.md`, mirror of
// `/docs-upload`. Same auth model. Returns the canonical public
// URL the consumer should write back into `packages.readme_url`.
//
// Markdown ships verbatim (utf-8); marked.js still parses it
// client-side on the docs site.
async function handleReadmeUpload(req: Request): Promise<Response> {
  let body: unknown
  try {
    body = await req.json()
  } catch (_) {
    return text('invalid JSON body', 400)
  }
  if (typeof body !== 'object' || body === null) {
    return text('body must be a JSON object', 400)
  }
  const b = body as Record<string, unknown>
  if (typeof b.name !== 'string' || !b.name) return text("'name' must be a non-empty string", 400)
  if (typeof b.version !== 'string' || !b.version) return text("'version' must be a non-empty string", 400)
  if (typeof b.readme !== 'string') return text("'readme' must be a string", 400)

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !serviceKey) {
    console.error('SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing')
    return text('server misconfigured', 500)
  }
  const client = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const short = b.name.replace(/^@hatch:/, '').replace(/[:@/]/g, '_')
  const key = `${short}/${b.version}/README.md`
  const payload = new TextEncoder().encode(b.readme)

  const { error: upErr } = await client
    .storage
    .from('package-readmes')
    .upload(key, payload, {
      contentType: 'text/markdown; charset=utf-8',
      upsert: true,
    })
  if (upErr) {
    console.error('storage upload failed:', upErr)
    return json({ error: upErr.message ?? 'storage error' }, 500)
  }

  const { data: pub } = client.storage.from('package-readmes').getPublicUrl(key)
  return json({ url: pub.publicUrl, key })
}

async function handleTag(req: Request): Promise<Response> {
  let body: unknown
  try {
    body = await req.json()
  } catch (_) {
    return text('invalid JSON body', 400)
  }
  if (typeof body !== 'object' || body === null) {
    return text('body must be a JSON object', 400)
  }
  const b = body as Record<string, unknown>
  if (typeof b.tag !== 'string' || !b.tag) return text("'tag' must be a non-empty string", 400)
  if (typeof b.sha !== 'string' || !b.sha) return text("'sha' must be a non-empty string", 400)

  // Default to this function's home repo. The bot is deployed
  // per-project; if it ever serves a second project, callers
  // can still override per-request.
  const owner = typeof b.owner === 'string' && b.owner ? b.owner : 'wrenlift'
  const repo  = typeof b.repo  === 'string' && b.repo  ? b.repo  : 'hatch'

  const appId = Deno.env.get('HATCH_GH_APP_ID')
  const privateKey = Deno.env.get('HATCH_GH_APP_PRIVATE_KEY')
  if (!appId || !privateKey) {
    console.error('HATCH_GH_APP_ID / HATCH_GH_APP_PRIVATE_KEY missing')
    return text('server misconfigured: GitHub App credentials unset', 500)
  }

  // `@octokit/auth-app` handles JWT signing (RS256) AND the
  // PKCS#1 → PKCS#8 dance Web Crypto needs — passing the raw PEM
  // GitHub gives you Just Works. Cheap to construct per call;
  // the underlying Octokit instance caches installation tokens
  // by id but each invocation here is a fresh request so caching
  // doesn't matter.
  const auth = createAppAuth({ appId, privateKey })

  // Look up the installation rather than hard-coding the id.
  // Lets the App stay portable if it gets installed on more
  // repos / orgs later without re-deploying this function.
  const { token: appJwt } = await auth({ type: 'app' })
  const instResp = await fetch(
    `https://api.github.com/repos/${owner}/${repo}/installation`,
    {
      headers: {
        Authorization: `Bearer ${appJwt}`,
        Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      },
    },
  )
  if (!instResp.ok) {
    const detail = await instResp.text()
    console.error('installation lookup failed', instResp.status, detail)
    return json(
      { error: 'installation lookup failed', status: instResp.status, detail },
      502,
    )
  }
  const inst = await instResp.json() as { id: number }

  const { token } = await auth({ type: 'installation', installationId: inst.id })

  // Create the ref. GitHub returns 422 when the ref already
  // exists — treat that as success (sweep is idempotent and the
  // caller's intent is "ensure this tag exists, pointing roughly
  // here", not "fail unless I'm the original creator").
  const refResp = await fetch(
    `https://api.github.com/repos/${owner}/${repo}/git/refs`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ ref: `refs/tags/${b.tag}`, sha: b.sha }),
    },
  )
  if (refResp.status === 422) {
    return json({ ok: true, tag: b.tag, status: 'exists' })
  }
  if (!refResp.ok) {
    const detail = await refResp.text()
    console.error('create ref failed', refResp.status, detail)
    return json(
      { error: 'create ref failed', status: refResp.status, detail },
      502,
    )
  }
  const created = await refResp.json() as { ref: string }
  return json({ ok: true, tag: b.tag, status: 'created', ref: created.ref })
}

// Hosts the proxy will forward to. Mirrors `wasm/serve.js`'s
// allowlist so dev-server and Edge Function accept the same set
// of upstreams. Override at deploy with `HATCH_PROXY_ALLOW=`
// (comma-separated) for a private mirror.
const DEFAULT_PROXY_ALLOW = [
  'https://github.com/',
  'https://objects.githubusercontent.com/',
  'https://gitlab.com/',
  'https://codeberg.org/',
]
function proxyAllowlist(): string[] {
  const env = Deno.env.get('HATCH_PROXY_ALLOW')
  if (!env) return DEFAULT_PROXY_ALLOW
  return env.split(',').map((s: string) => s.trim()).filter(Boolean)
}

function corsPreflight(): Response {
  return new Response(null, {
    status: 204,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Access-Control-Allow-Headers': '*',
      'Access-Control-Max-Age': '86400',
    },
  })
}

async function handleProxy(req: Request): Promise<Response> {
  const target = new URL(req.url).searchParams.get('url')
  if (!target) {
    return new Response('400 Bad Request: missing ?url=', {
      status: 400,
      headers: { 'content-type': 'text/plain', 'Access-Control-Allow-Origin': '*' },
    })
  }
  const allowlist = proxyAllowlist()
  if (!allowlist.some((prefix) => target.startsWith(prefix))) {
    return new Response(`403 Forbidden: ${target} is not in the proxy allowlist`, {
      status: 403,
      headers: { 'content-type': 'text/plain', 'Access-Control-Allow-Origin': '*' },
    })
  }
  let upstream: Response
  try {
    upstream = await fetch(target, { redirect: 'follow' })
  } catch (err) {
    return new Response(`502 Bad Gateway: ${err}`, {
      status: 502,
      headers: { 'content-type': 'text/plain', 'Access-Control-Allow-Origin': '*' },
    })
  }
  // Stream the body through; drop hop-by-hop headers, keep
  // content-type and content-length, and stamp our CORS + CORP
  // so the browser will accept the response under any embedder
  // policy.
  const headers = new Headers()
  const contentType = upstream.headers.get('content-type')
  if (contentType) headers.set('content-type', contentType)
  headers.set('Access-Control-Allow-Origin', '*')
  headers.set('Cross-Origin-Resource-Policy', 'cross-origin')
  return new Response(upstream.body, { status: upstream.status, headers })
}

Deno.serve(async (req: Request) => {
  // --- Routing -------------------------------------------------
  // `/`        — health check so you can `curl …/hatch-bot`.
  // `/publish` — package upsert against the Supabase `packages` table.
  // `/tag`     — create `refs/tags/<tag>` on a configured repo via
  //              an internal GitHub App installation token.
  // `/proxy`   — allowlisted CORS proxy for the wasm playground.
  const url = new URL(req.url)
  const path = url.pathname.replace(/^\/hatch-bot/, '') || '/'

  if (path === '/' && req.method === 'GET') {
    return json({ ok: true, service: 'hatch-bot', ts: new Date().toISOString() })
  }

  if (path === '/publish' && req.method === 'POST') {
    const authErr = checkAuth(req)
    if (authErr) return authErr
    return handlePublish(req)
  }

  if (path === '/tag' && req.method === 'POST') {
    const authErr = checkAuth(req)
    if (authErr) return authErr
    return handleTag(req)
  }

  if (path === '/docs-upload' && req.method === 'POST') {
    const authErr = checkAuth(req)
    if (authErr) return authErr
    return handleDocsUpload(req)
  }

  if (path === '/readme-upload' && req.method === 'POST') {
    const authErr = checkAuth(req)
    if (authErr) return authErr
    return handleReadmeUpload(req)
  }

  if (path === '/proxy') {
    if (req.method === 'OPTIONS') return corsPreflight()
    if (req.method === 'GET')     return handleProxy(req)
    return new Response('405 Method Not Allowed', {
      status: 405,
      headers: { 'content-type': 'text/plain', 'Access-Control-Allow-Origin': '*' },
    })
  }

  return text('not found', 404)
})
