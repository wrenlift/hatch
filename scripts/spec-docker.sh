#!/usr/bin/env bash
# spec-docker.sh — run hatch package specs inside a Linux x86_64
# container so platform-specific failures (JIT tiered flakes on
# x86_64, plugin dlopen errors, hardware-bound test gating, etc.)
# reproduce locally without round-tripping CI.
#
# Mirrors the build + run pipeline of
# `.github/workflows/regression.yml`'s Specs job step-for-step:
# build wlift + plugins, stage dylibs into each package's libs/,
# topo pre-build into a local cache under HATCH_OFFLINE, then
# loop every package's `*.spec.wren`.
#
# Usage:
#
#   scripts/spec-docker.sh                 # all packages, MODE=tiered
#   scripts/spec-docker.sh hatch-fsm       # only matching packages
#   scripts/spec-docker.sh -m interpreter  # mode override
#   scripts/spec-docker.sh -m tiered hatch-fsm
#
# Env:
#
#   WLIFT_SRC   — path to wren_lift checkout. Defaults to the
#                 sibling `../wren_lift` directory next to this
#                 hatch repo.
#   IMAGE_TAG   — docker image tag to use. Default
#                 `hatch-spec-runner:latest`.
#
# State persisted across runs (so the second run is ~10s):
#
#   docker volume hatch-spec-target   — cargo target/
#   docker volume hatch-spec-cargo    — cargo registry + git deps
#
# Wipe them with:
#
#   docker volume rm hatch-spec-target hatch-spec-cargo
#
# when you want a from-scratch rebuild (e.g. to mimic CI's
# cache-cold path).

set -eu

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------

MODE="${MODE:-tiered}"
PKG_FILTER=""

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--mode)
      MODE="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '1,40p' "$0"
      exit 0
      ;;
    -*)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
    *)
      PKG_FILTER="$1"
      shift
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Resolve paths + sanity-check Docker
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WLIFT_SRC="${WLIFT_SRC:-$(cd "$REPO_ROOT/.." && pwd)/wren_lift}"
IMAGE_TAG="${IMAGE_TAG:-hatch-spec-runner:latest}"

if ! command -v docker >/dev/null 2>&1; then
  echo "::error::docker not on PATH"
  echo "  install Docker Desktop (macOS) or docker-ce (linux) and retry"
  exit 2
fi
if [ ! -d "$WLIFT_SRC" ]; then
  echo "::error::WLIFT_SRC=$WLIFT_SRC doesn't exist"
  echo "  set WLIFT_SRC to your wren_lift checkout, e.g.:"
  echo "    WLIFT_SRC=\$HOME/Vibranium/wren_lift scripts/spec-docker.sh"
  exit 2
fi

DOCKERFILE="$SCRIPT_DIR/spec-docker.Dockerfile"
if [ ! -f "$DOCKERFILE" ]; then
  echo "::error::missing $DOCKERFILE"
  exit 2
fi

# ---------------------------------------------------------------------------
# Build image (cached unless Dockerfile changes)
# ---------------------------------------------------------------------------

echo "==> building image $IMAGE_TAG (linux/amd64, cached unless spec-docker.Dockerfile changed)"
docker build \
  --platform linux/amd64 \
  --quiet \
  -t "$IMAGE_TAG" \
  -f "$DOCKERFILE" \
  "$SCRIPT_DIR" > /dev/null

# ---------------------------------------------------------------------------
# Run specs
# ---------------------------------------------------------------------------

# Named volumes hold cargo target/ + registry across runs. On macOS the
# bind-mounted host filesystem goes through virtiofs which is slow for
# cargo's many-small-files writes; keeping target/ inside a docker
# volume on linuxfs makes incremental rebuilds finish in seconds.
docker run \
  --rm \
  -it \
  --platform linux/amd64 \
  -v "$WLIFT_SRC:/wren_lift" \
  -v "$REPO_ROOT:/hatch" \
  -v hatch-spec-target:/spec-target \
  -v hatch-spec-cargo:/spec-cargo \
  -e WLIFT_SRC=/wren_lift \
  -e HATCH_DIR=/hatch \
  -e CARGO_TARGET_DIR=/spec-target \
  -e CARGO_HOME=/spec-cargo \
  -e MODE="$MODE" \
  -e PKG_FILTER="$PKG_FILTER" \
  -e HATCH_CI_SKIP="${HATCH_CI_SKIP:-hatch-audio hatch-gpu hatch-window hatch-postfx}" \
  "$IMAGE_TAG"
