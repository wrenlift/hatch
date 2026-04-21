#!/usr/bin/env bash
#
# Mint a long-lived Supabase JWT for the hatch-bot CI account.
#
# Inputs (env vars OR positional args):
#
#   SUPABASE_JWT_SECRET   — copied from Supabase → Settings → API →
#                           JWT Settings → "JWT Secret" (HS256 key).
#   HATCH_BOT_USER_UUID   — UUID of the bot user row in auth.users.
#                           Create one first via Authentication →
#                           Users → Add user.
#   EXP_SECONDS           — optional; seconds until expiry. Defaults
#                           to 5 years.
#
# Output: the signed JWT, one line on stdout. Paste it into
# GitHub → Settings → Secrets and variables → Actions → HATCH_TOKEN.
#
# Usage:
#   SUPABASE_JWT_SECRET=... HATCH_BOT_USER_UUID=... ./mint-ci-token.sh
#
# Zero deps beyond a POSIX shell + openssl. Works on macOS and Linux.

set -euo pipefail

secret="${SUPABASE_JWT_SECRET:-${1:-}}"
uuid="${HATCH_BOT_USER_UUID:-${2:-}}"
# Default: five 365-day years from now. Clean multiples of 86400.
default_exp=$((5 * 365 * 86400))
exp_offset="${EXP_SECONDS:-$default_exp}"

if [ -z "$secret" ] || [ -z "$uuid" ]; then
  echo "usage: SUPABASE_JWT_SECRET=... HATCH_BOT_USER_UUID=... $0" >&2
  echo "   or: $0 <secret> <uuid>" >&2
  exit 1
fi

now=$(date -u +%s)
exp=$((now + exp_offset))

# --- base64url encode (no padding) --------------------------------
# openssl emits standard base64 with `+ / =` — swap to `- _` and
# strip padding per RFC 7515.
b64url() {
  openssl base64 -A \
    | tr '+/' '-_' \
    | tr -d '='
}

header_json='{"alg":"HS256","typ":"JWT"}'

# Claims:
#   sub  — the auth.users UUID; RLS policies read this as auth.uid()
#   role — "authenticated" satisfies any `request.jwt.claim.role`
#          checks in policies
#   aud  — Supabase's default audience
#   iat  — issued-at timestamp
#   exp  — expiry timestamp
payload_json=$(printf '{"sub":"%s","role":"authenticated","aud":"authenticated","iat":%d,"exp":%d}' \
  "$uuid" "$now" "$exp")

header_b64=$(printf '%s' "$header_json"  | b64url)
payload_b64=$(printf '%s' "$payload_json" | b64url)

signing_input="${header_b64}.${payload_b64}"

signature_b64=$(
  printf '%s' "$signing_input" \
    | openssl dgst -binary -sha256 -hmac "$secret" \
    | b64url
)

echo "${signing_input}.${signature_b64}"

# --- diagnostics to stderr ----------------------------------------
human_exp=$(date -u -r "$exp" "+%Y-%m-%d %H:%M:%S UTC" 2>/dev/null \
  || date -u -d "@$exp" "+%Y-%m-%d %H:%M:%S UTC")
{
  echo
  echo "minted JWT for sub=$uuid"
  echo "  iat = $now"
  echo "  exp = $exp  ($human_exp)"
} >&2
