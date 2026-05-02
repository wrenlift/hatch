# hatch.wrenlift.com runtime image.
#
# Two stages:
#
#   1. `builder` — installs the wlift + hatch CLIs from the
#      published install.sh. We pin to a tagged release at deploy
#      time via the `WLIFT_VERSION` build arg so an ambient
#      `latest` doesn't drift the runtime under our feet.
#
#   2. `runtime` — copies just the binaries + the workspace's
#      static assets and views; runs `hatch run` against `site/`
#      which builds + executes the workspace in-process.
#
# We don't `wlift main.wren` directly anymore — the runtime fix
# in wren_lift e02ffd7 made `hatch run` work end-to-end with
# multi-platform native libs, so the deploy can use the canonical
# CLI entry point.

FROM debian:bookworm-slim AS builder

ARG WLIFT_VERSION=latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl bash \
    && rm -rf /var/lib/apt/lists/*

# Install wlift + hatch into /usr/local/bin so the runtime stage
# can copy them without dragging the build chain along. Pin the
# release via WLIFT_VERSION; default `latest` resolves to the
# install.sh script's "newest GitHub release" branch.
#
# Pipe to `bash` not `sh` — install.sh uses `set -o pipefail`
# which dash (debian's /bin/sh) rejects with "Illegal option".
RUN curl -fsSL https://wrenlift.com/install.sh \
    | INSTALL_DIR=/usr/local/bin WLIFT_VERSION=${WLIFT_VERSION} bash

# ---------------------------------------------------------------

FROM debian:bookworm-slim AS runtime

# `hatch run` shells out to `curl` for catalog reads (lib/catalog.wren
# pulls index.toml from raw.githubusercontent.com). ca-certificates
# is what makes the HTTPS handshake against GitHub trustable.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/wlift /usr/local/bin/wlift
COPY --from=builder /usr/local/bin/hatch /usr/local/bin/hatch

WORKDIR /app
COPY hatchfile main.wren ./
COPY lib   ./lib
COPY views ./views
COPY public ./public

ENV PORT=3000
EXPOSE 3000

# `hatch run .` builds + runs the workspace; deps land in the
# container's per-process cache during boot. Catalog refresh runs
# on app boot then every 5 minutes thereafter.
CMD ["hatch", "run", "."]
