// hatch-bot — package publish endpoint for hatch CLI + CI.
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
// Body shape (JSON) mirrors the Rust `PackageRecord`:
//
//   { "name": "@hatch:foo", "version": "1.2.3",
//     "git":  "https://github.com/…", "description": "...",
//     "owner": "<uuid>" }          ← optional
//
// owner is optional; when present it's stored verbatim so
// auditing / listing by publisher still works without a real
// Supabase user row behind the request.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

interface PackageRecord {
  name: string
  version: string
  git: string
  description?: string
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
  if (b.description !== undefined && typeof b.description !== 'string') {
    return { ok: false, reason: "'description' must be a string when present" }
  }
  if (b.owner !== undefined && typeof b.owner !== 'string') {
    return { ok: false, reason: "'owner' must be a string when present" }
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

Deno.serve(async (req) => {
  // --- Routing -------------------------------------------------
  // `/` — health check so you can `curl …/hatch-bot` and see it's live.
  // `/publish` — the actual write endpoint.
  const url = new URL(req.url)
  const path = url.pathname.replace(/^\/hatch-bot/, '') || '/'

  if (path === '/' && req.method === 'GET') {
    return json({ ok: true, service: 'hatch-bot', ts: new Date().toISOString() })
  }

  if (path !== '/publish' || req.method !== 'POST') {
    return text('not found', 404)
  }

  // --- Auth ----------------------------------------------------
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

  // --- Body ----------------------------------------------------
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
})
