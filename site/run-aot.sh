#!/usr/bin/env bash
# Launcher for the AOT-built site_aot binary.
#
# Two CWD-dependences the site has on its package layout, both
# normalised here so the binary can be invoked from anywhere
# (systemd ExecStart, fly start, manual ./run-aot.sh, etc.):
#
#   1. Plugin dylibs: the binary tries "../packages/hatch-*/libs/"
#      relative paths first. Set DYLD_FALLBACK_LIBRARY_PATH to
#      cover every packages/*/libs/ so @hatch:sqlite (and any
#      future native plugin) resolves regardless of CWD.
#
#   2. Template + content paths: main.wren's FnLoader uses
#      "./views/<name>" and the guide routes read "content/*.md"
#      via the same relative-cwd assumption. `cd "$SITE_DIR"`
#      before exec so those resolve. Without this, `/guides/intro`
#      reads back as 'template not found: guide.html' on every
#      hit because the loader sees an empty ./views/ tree.
#
# Usage:
#   PORT=3000 hatch/site/run-aot.sh
#
# Production Docker images: bake DYLD_FALLBACK + WORKDIR into the
# image and skip this wrapper. This is for local / staging where
# the dylibs ship next to source and CWD isn't pre-set.

set -eu

# Resolve script dir → workspace root (two levels up: site → hatch → workspace).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Build the fallback path from every packages/*/libs/ that exists. Adding
# a missing dir is harmless; missing the right one is what bites.
PLUGIN_DIRS="$(find "$WORKSPACE/hatch/packages" -maxdepth 3 -name libs -type d | tr '\n' ':' | sed 's/:$//')"

# DYLD_FALLBACK_LIBRARY_PATH (not DYLD_LIBRARY_PATH): macOS strips
# DYLD_LIBRARY_PATH for signed binaries inheriting from a launchd
# parent, and the fallback variant is the supported override for
# packaged runtimes.
export DYLD_FALLBACK_LIBRARY_PATH="${DYLD_FALLBACK_LIBRARY_PATH:-}${DYLD_FALLBACK_LIBRARY_PATH:+:}$PLUGIN_DIRS"

# Change to the site dir so the FnLoader's ./views/ and guide
# routes' content/*.md resolve. Use absolute exec path because $PWD
# changed; relative "./site_aot" would resolve the same here, but
# the absolute path is robust against future relocation.
cd "$SCRIPT_DIR"

# Seed the local index.toml mirror that Catalog.fetchAndParse_
# prefers over the network fetch. raw.githubusercontent.com is
# reachable in production but flaky on a cold dev box (and
# unavailable in air-gapped CI sandboxes), so we always seed
# the workspace mirror and let the background refresher pull
# fresh data later if the network is up.
#
# Self-heal: if a previous run was SIGKILL'd before the
# cleanup watchdog finished, an orphaned index.toml may already
# be sitting in $SCRIPT_DIR. Treat it as ours (and remove it)
# only when it byte-matches the workspace mirror — a
# hand-staged variant (operator copied a tweaked index.toml in
# for testing) won't match, so it's preserved.
if [[ -f "$SCRIPT_DIR/index.toml" && -f "$WORKSPACE/hatch/index.toml" ]]; then
  if cmp -s "$SCRIPT_DIR/index.toml" "$WORKSPACE/hatch/index.toml"; then
    rm -f "$SCRIPT_DIR/index.toml"
  fi
fi

SEEDED_INDEX=""
if [[ -f "$WORKSPACE/hatch/index.toml" && ! -f "$SCRIPT_DIR/index.toml" ]]; then
  cp "$WORKSPACE/hatch/index.toml" "$SCRIPT_DIR/index.toml"
  SEEDED_INDEX="$SCRIPT_DIR/index.toml"
fi

# Cleanup via watchdog subshell: bash trap-on-EXIT does not fire
# after `exec` (the shell is gone), and a foreground-wait + trap
# pattern stalls on krio's SIGTERM handler. The watchdog polls
# our own PID until it disappears — when the exec'd binary
# terminates, its PID (== ours, preserved across exec) is freed
# and the watchdog removes the seeded mirror.
#
# The watchdog is launched via `exec -a hatch-mirror-cleanup`
# inside its subshell so it shows up in `ps` / `pgrep` as
# `hatch-mirror-cleanup`, NOT `bash` or `run-aot.sh`. Operators
# (and CI teardown scripts) that SIGKILL the whole site by
# pattern — `pkill -f "site_aot|run-aot.sh"` — no longer reap
# the cleanup process before it gets a chance to remove the
# seeded index.toml. Without this rename, a process-group kill
# leaves the orphaned mirror behind and the next launch trips
# the "someone hand-staged it" branch, then never updates.
if [[ -n "$SEEDED_INDEX" ]]; then
  (
    exec -a hatch-mirror-cleanup bash -c '
      PARENT_PID="$1"
      SEEDED_INDEX="$2"
      while kill -0 "$PARENT_PID" 2>/dev/null; do sleep 1; done
      rm -f "$SEEDED_INDEX"
    ' hatch-mirror-cleanup "$$" "$SEEDED_INDEX"
  ) &
  disown
fi

exec "$SCRIPT_DIR/site_aot" "$@"
