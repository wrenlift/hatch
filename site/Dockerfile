# hatch.wrenlift.com runtime image.
#
# Three stages:
#
#   1. `builder` — installs the wlift + hatch CLIs from the
#      published install.sh. We pin to a tagged release at deploy
#      time via the `WLIFT_VERSION` build arg so an ambient
#      `latest` doesn't drift the runtime under our feet.
#
#   2. `bundle` — copies the workspace in and runs `hatch build`
#      against it, fetching every transitive dep from the registry
#      and emitting a single self-contained `site.hatch` bundle.
#      This work happens once at image-build time so each cold
#      machine boot is just `wlift site.hatch` (sub-second) rather
#      than re-resolving the dep tree from GitHub on every start.
#
#   3. `runtime` — minimal, copies just the wlift binary + the
#      pre-built bundle + static assets. No `hatch` CLI, no
#      curl-shelled-out registry probes at runtime.

FROM debian:trixie-slim AS builder

# Pin the wlift release tag so the Docker layer cache invalidates
# whenever we move forward. Leaving this blank lets `install.sh`
# resolve `/releases/latest` at build time, but Docker can't see
# through that — once a layer with `WLIFT_VERSION=` runs once, every
# subsequent build hits the cache and keeps the old binary even
# after a new release is cut. Bump this string in lockstep with each
# new tag instead.
ARG WLIFT_VERSION=v0.1.16

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl bash \
    && rm -rf /var/lib/apt/lists/*

# Install wlift + hatch into /usr/local/bin so the bundle + runtime
# stages can copy them without dragging the build chain along.
#
# Pipe to `bash` not `sh` — install.sh uses `set -o pipefail`
# which dash (debian's /bin/sh) rejects with "Illegal option".
RUN curl -fsSL https://wrenlift.com/install.sh \
    | INSTALL_DIR=/usr/local/bin WLIFT_VERSION=${WLIFT_VERSION} bash

# ---------------------------------------------------------------

FROM builder AS bundle

# The site's workspace. Building from inside the image so dep
# resolution + transitive `.hatch` fetches happen once at image
# build time, not on every cold machine boot.
WORKDIR /build
COPY hatchfile main.wren ./
COPY lib   ./lib
COPY views ./views
COPY public ./public
COPY content ./content

# `hatch build` resolves [dependencies] from the registry, fetches
# each `.hatch` bundle, and emits a self-contained `site.hatch`.
# Per-package docs JSON lives on Supabase Storage now (uploaded
# by `hatch publish` at publish time), so the site doesn't need
# to ship pre-rendered files — `lib/api.wren` curls the catalog
# row's `docs_url` at request time with an in-process cache.
RUN hatch build . --out site.hatch

# ---------------------------------------------------------------

FROM debian:trixie-slim AS runtime

# `curl` lives here because `lib/catalog.wren` shells out to it
# for the GitHub-hosted index.toml refresh. ca-certificates makes
# the HTTPS handshake trustable.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/local/bin/wlift /usr/local/bin/wlift

WORKDIR /app
# The pre-built bundle carries every Wren module; `views/`,
# `content/`, and `public/` ride alongside because the site reads
# them from disk at request time:
#
#   * `views/<name>.html`   — `FnLoader` template lookup
#   * `content/<slug>.md`   — guide / blog markdown
#   * `public/assets/...`   — `Static.serve` middleware
#
# Per-package API docs JSON is no longer in `content/`; the site
# curls each row's `docs_url` (Supabase Storage) at request time
# instead.
COPY --from=bundle /build/site.hatch ./site.hatch
COPY --from=bundle /build/views    ./views
COPY --from=bundle /build/content  ./content
COPY --from=bundle /build/public   ./public

ENV PORT=3000
EXPOSE 3000

# Direct bundle execution. No registry probes, no dep resolution,
# no `hatch` CLI in the runtime image — just the bundle the build
# stage produced.
CMD ["wlift", "site.hatch"]
