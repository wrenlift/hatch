#!/usr/bin/env bash
# Redispatch publish-pkg.yml for every pure-Wren package in
# `packages/`. The action-gh-release upsert means each run rebuilds
# the .hatch bundle against the latest main source (now with the
# lexer-promoted module docs + `///` reformats embedded in the
# Docs section) and replaces the existing release asset — no
# version bump required.
#
# Plugin-backed packages (audio, gpu, image, physics, sqlite,
# window) are skipped here; they're handled by publish-plugin.yml,
# which carries its own per-os-arch staging matrix.
#
# Usage:
#   ./scripts/redispatch-publish-pkg.sh         # fire all
#   ./scripts/redispatch-publish-pkg.sh --dry   # just print

set -euo pipefail

REPO="wrenlift/hatch"
DRY=false
[ "${1:-}" = "--dry" ] && DRY=true

cd "$(dirname "$0")/.."

pkgs=()
for hf in packages/*/hatchfile; do
  pkg=$(basename "$(dirname "$hf")")
  case "$pkg" in
    hatch-cli|hatch-hello) continue ;;
  esac
  if grep -q '^\[plugin_source\]' "$hf"; then
    continue
  fi
  pkgs+=("$pkg")
done

echo "will dispatch ${#pkgs[@]} packages:"
printf '  %s\n' "${pkgs[@]}"

if $DRY; then
  echo
  echo "(dry run — pass without --dry to actually dispatch)"
  exit 0
fi

failed=()
for pkg in "${pkgs[@]}"; do
  if gh workflow run publish-pkg.yml -R "$REPO" -f package="$pkg" >/dev/null 2>&1; then
    echo "  dispatched: $pkg"
  else
    echo "  FAILED:     $pkg"
    failed+=("$pkg")
  fi
done

if [ ${#failed[@]} -gt 0 ]; then
  echo
  echo "${#failed[@]} dispatches failed:"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi

echo
echo "all dispatched. tail with:"
echo "  gh run list -R $REPO --workflow=publish-pkg.yml --limit 32"
