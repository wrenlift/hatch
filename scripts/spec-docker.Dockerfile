# Linux x86_64 spec runner image.
#
# Mirrors the runtime + build environment that `.github/workflows/
# regression.yml` provisions on `ubuntu-latest`, so any platform-
# specific failure that surfaces in CI (JIT tiered flakes on x86_64,
# plugin dlopen errors, hardware-bound test gating, etc.) reproduces
# locally via this image without committing + pushing first.
#
# Base: official Rust image on Debian bookworm. Bookworm ships
# Python 3.11 by default, which `regression.yml`'s pre-build helpers
# rely on for `tomllib` — and gives us the same `cargo build`
# toolchain CI uses.
#
# The image deliberately doesn't bake in a wlift binary or staged
# plugins; those build inside the container against the mounted
# `/wren_lift` source so the spec runner always exercises the
# current local checkout, not a frozen snapshot. Cargo target +
# registry are persisted via named docker volumes from
# `spec-docker.sh`, so the second run only recompiles changed
# crates.

# Pin to linux/amd64 explicitly so the image always matches CI's
# `ubuntu-latest` runner architecture. On Apple Silicon hosts Docker
# defaults to linux/arm64, which dodges the JIT codegen paths we
# want to exercise — Cranelift emits different machine code per
# target, and tiered-mode flakes that surface in x86_64 CI won't
# reproduce under an arm64 image. The trade-off is slower builds
# (QEMU / Rosetta emulation, ~3-5× compile time), but the whole
# point of this image is to reproduce CI faithfully.
FROM --platform=linux/amd64 rust:1-bookworm

# Plugin system libraries — same set as `regression.yml`'s
# "Install plugin system deps (linux)" step:
#
#   libasound2-dev   → wlift_audio (cpal/alsa-sys)
#   libudev-dev      → wlift_window (winit input device enumeration)
#   libxkbcommon-dev,
#   libwayland-dev,
#   libx11-dev,
#   libxcb1-dev,
#   libxrandr-dev,
#   libxinerama-dev,
#   libxcursor-dev,
#   libxi-dev        → wlift_window (winit X11 + wayland backends)
#
# python3 is already present via base; explicit here to fail fast
# if the base ever drops it.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libasound2-dev \
      libudev-dev \
      libxkbcommon-dev \
      libwayland-dev \
      libx11-dev \
      libxcb1-dev \
      libxrandr-dev \
      libxinerama-dev \
      libxcursor-dev \
      libxi-dev \
      python3 \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /hatch

# The entry script lives inside the mounted /hatch volume so edits
# don't require an image rebuild.
ENTRYPOINT ["/usr/bin/env", "bash", "/hatch/scripts/spec-docker-run.sh"]
