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
ARG WLIFT_VERSION=v0.1.1

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
# each `.hatch` bundle, and emits a single self-contained bundle
# at `/build/site.hatch`. Runtime then loads that bundle directly
# without reaching back to the registry.
RUN hatch build . --out site.hatch

# Backfill the API docs JSON for every @hatch:* package in the
# live registry, not just the site's transitive deps. We pull
# `index.toml` from GitHub raw, walk every entry, fetch the
# matching `.hatch` bundle from the matching release tag, and
# run `hatch docs` against it. Runtime then reads
# `content/api/<short>.json` for any package the user navigates
# to without per-request CLI spawn or registry probe.
#
# Each bundle is 1–3MB; ~40 packages × ~2MB = ~80MB of
# build-time downloads, fine on Fly's remote builder. The cache
# layer is reused on subsequent builds when the index hasn't
# moved (Docker keys this RUN by the file content of the inputs
# above, so an unchanged index.toml + matching releases skips
# the work).
RUN set -eu; \
    mkdir -p content/api; \
    curl -fsSL https://raw.githubusercontent.com/wrenlift/hatch/main/index.toml \
        -o /tmp/index.toml; \
    # Index entries look like `[packages."@hatch:foo-1.2.3"]`. We
    # only want the latest version per package — pull every
    # `name-version` substring with grep (portable across mawk /
    # gawk / busybox), then have awk pick the highest semver per
    # name and emit `<dir>\t<version>` pairs.
    grep -oE '@hatch:[a-z0-9_-]+-[0-9]+\.[0-9]+\.[0-9]+' /tmp/index.toml \
        | sed 's/^@hatch://' \
        | awk -F'-' '{
            n = NF;
            ver = $n;
            name = $1;
            for (i = 2; i < n; i++) name = name "-" $i;
            split(ver, a, ".");
            split(latest[name], b, ".");
            if (latest[name] == "" \
                || (a[1]+0)  > (b[1]+0) \
                || ((a[1]+0) == (b[1]+0) && (a[2]+0)  > (b[2]+0)) \
                || ((a[1]+0) == (b[1]+0) && (a[2]+0) == (b[2]+0) && (a[3]+0) > (b[3]+0))) {
                latest[name] = ver;
            }
        }
        END { for (n in latest) printf "hatch-%s\t%s\n", n, latest[n]; }' \
        > /tmp/pkgs.tsv; \
    while IFS=$'\t' read -r dir ver; do \
        # Skip the CLI / scaffold entries that aren't real packages.
        case "$dir" in hatch-cli|hatch-hello) continue ;; esac; \
        short="${dir#hatch-}"; \
        out="content/api/${short}.json"; \
        if [ -s "$out" ]; then continue; fi; \
        url="https://github.com/wrenlift/hatch/releases/download/publish/${dir}%40${ver}/${dir}-${ver}.hatch"; \
        tmp="/tmp/${dir}-${ver}.hatch"; \
        if curl -fsSL -o "$tmp" "$url" 2>/dev/null; then \
            hatch docs "$tmp" --out "$out" 2>/dev/null \
                && echo "  -> $out  ($(wc -c < "$out") bytes)" \
                || echo "  !! docs failed for $dir@$ver"; \
            rm -f "$tmp"; \
        else \
            echo "  -- no release at $url"; \
        fi; \
    done < /tmp/pkgs.tsv; \
    rm -f /tmp/index.toml /tmp/pkgs.tsv; \
    echo "::: content/api/ summary :::"; \
    ls -1 content/api/ | wc -l; \
    ls -la content/api/ | head -20

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
# All three are reads-only at runtime, so a single `COPY` from
# the bundle stage is enough.
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
