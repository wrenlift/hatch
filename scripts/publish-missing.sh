#!/usr/bin/env bash
#
# Push `publish/<pkg-dir>@<version>` tags for any package whose
# tag doesn't already exist on origin. The pushed tags fire
# `.github/workflows/publish-pkg.yml` (pure-Wren) and
# `publish-plugin.yml` (plugin-backed) automatically — those
# already gate on `[plugin_source]` so each tag fans out to
# exactly one of them.
#
# Usage (from anywhere; the script jumps to the hatch repo root):
#
#   scripts/publish-missing.sh           # interactive — prompts before push
#   scripts/publish-missing.sh --yes     # skip confirmation
#   scripts/publish-missing.sh --dry-run # list missing tags, push nothing
#
# The bypass on the protect-main ruleset only covers your local
# identity (org admin), so this script is the canonical "publish
# what's pending" loop. Bump `version =` in a hatchfile, merge to
# main, run this from a clean checkout.

set -eu

# --- Args ------------------------------------------------------
yes=0
dry=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes)     yes=1 ;;
    -n|--dry-run) dry=1 ;;
    -h|--help)
      sed -n '2,/^set -eu/p' "$0" | sed -e 's/^# \{0,1\}//' -e '/^set -eu/d'
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 1
      ;;
  esac
done

# --- Locate repo root -----------------------------------------
# Script lives at `scripts/publish-missing.sh`, so the repo root
# is one up regardless of where the user invoked us from.
script_dir=$(cd "$(dirname "$0")" && pwd)
cd "$script_dir/.."

if [ ! -d packages ]; then
  echo "expected to be in the hatch repo root (no packages/ dir)" >&2
  exit 1
fi

# --- Refresh tag list -----------------------------------------
# `--prune-tags` drops any local tag that's been deleted on
# origin so we don't miscount it as "exists". Quiet so the only
# stdout line is the actual report below.
git fetch --tags --prune-tags --quiet origin

# --- Discover --------------------------------------------------
missing=()
skipped=()
while IFS= read -r hf; do
  pkg_dir=$(basename "$(dirname "$hf")")
  version=$(awk -F'"' '/^version *=/ {print $2; exit}' "$hf")
  if [ -z "$version" ]; then
    echo "warn: $hf has no version, skipping $pkg_dir" >&2
    continue
  fi
  tag="publish/${pkg_dir}@${version}"
  if git rev-parse -q --verify "refs/tags/${tag}" > /dev/null 2>&1; then
    skipped+=("$tag")
  else
    missing+=("$tag")
  fi
done < <(find packages -mindepth 2 -maxdepth 2 -name hatchfile | sort)

echo "already published: ${#skipped[@]}"
echo "missing:           ${#missing[@]}"

if [ "${#missing[@]}" -eq 0 ]; then
  echo "nothing to do."
  exit 0
fi

echo
echo "missing tags:"
printf '  %s\n' "${missing[@]}"
echo

if [ "$dry" -eq 1 ]; then
  echo "(dry-run; nothing pushed)"
  exit 0
fi

# --- Confirm ---------------------------------------------------
if [ "$yes" -eq 0 ]; then
  printf "push all %d tag(s) to origin? [y/N] " "${#missing[@]}"
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "aborted."; exit 0 ;;
  esac
fi

# --- Push ------------------------------------------------------
# One tag per push so a failure on tag N doesn't strand tags
# 1..N-1 in a half-pushed state. Annotated tags so the publish
# workflows pick up the message in `softprops/action-gh-release`.
fail=0
for tag in "${missing[@]}"; do
  if git tag -a "$tag" -m "$tag" 2>/dev/null; then
    :
  else
    # Likely a stale local tag from an earlier abort. Replace
    # it cleanly so the push reflects current HEAD.
    git tag -d "$tag" > /dev/null
    git tag -a "$tag" -m "$tag"
  fi
  if git push origin "$tag"; then
    echo "pushed $tag"
  else
    echo "FAILED $tag" >&2
    fail=1
  fi
done

exit $fail
