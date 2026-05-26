# hatch.wrenlift.com runtime image — AOT-compiled.
#
# Four stages:
#
#   1. `wlift-builder` — clones the wren_lift source at the
#      pinned tag and runs `cargo build --release --features aot`
#      to produce both the `wlift` / `hatch` binaries AND the
#      `libwren_lift.a` staticlib that `wlift --aot` links the
#      generated AOT object against. The published release
#      tarballs don't currently ship the staticlib (it's only in
#      the cargo build tree), so we always build from source here
#      to keep the pipeline self-contained.
#
#   2. `bundle` — copies the workspace in and runs `hatch build`
#      against it, fetching every transitive dep from the
#      registry and emitting a self-contained `site.hatch`. The
#      same stage then invokes `wlift --aot ./site ./site.hatch`
#      to produce a standalone native binary that embeds the
#      runtime + every reachable module's lowered MIR. No
#      interpreter is needed at request time.
#
#   3. `runtime` — minimal, copies just the AOT-compiled binary
#      and the static asset trees. No `wlift`, no `hatch`, no
#      `.hatch` bundle — the binary is fully self-contained.

# ---------------------------------------------------------------
FROM rust:1-trixie AS wlift-builder

# wren_lift source revision. Accepts either a tag (`v0.1.17`) or
# a branch (`main`). Defaulting to `main` until the AOT-stability
# fixes land in a tagged release — `wlift_aot_invoke_sm_method`
# fiber-rooting (commit d9f22fc), Phase 7 default flip (c2a9f96),
# Pass-1 covered_fps (d8739d9), and the named-closure stack-trace
# plumbing (7ad5c2e) all post-date v0.1.17 and the site needs
# them to run AOT without crashing. Flip back to a `v…` tag once
# v0.1.18 ships.
ARG WLIFT_VERSION=main
ARG WLIFT_REPO=https://github.com/wrenlift/WrenLift.git

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git ca-certificates pkg-config cmake build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch ${WLIFT_VERSION} ${WLIFT_REPO} .

# `--features aot` pulls in the Cranelift object-emitter + the
# AOT bootstrap shim. Building both the `wlift` and `hatch` bins
# also produces `libwren_lift.a` (the lib crate's `staticlib`
# crate-type) — `wlift --aot` looks for it next to its own
# binary, so the bundle stage copies all three side by side.
RUN cargo build --release --features aot --bin wlift --bin hatch

# ---------------------------------------------------------------
FROM debian:trixie-slim AS bundle

# `bash` is required for the hatch CLI's shell-out helpers;
# `build-essential` provides the `cc` invocation `wlift --aot`
# uses to link the generated AOT object against the WrenLift
# staticlib. `curl` + `ca-certificates` are kept for any
# registry fetches `hatch build` makes against github.com.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl bash build-essential \
    && rm -rf /var/lib/apt/lists/*

# wlift discovers `libwren_lift.a` via `<exe_dir>/libwren_lift.a`
# (or `WLIFT_STATICLIB` if set) — copying all three into the same
# /usr/local/bin keeps the discovery path simple.
COPY --from=wlift-builder /src/target/release/wlift            /usr/local/bin/wlift
COPY --from=wlift-builder /src/target/release/hatch            /usr/local/bin/hatch
COPY --from=wlift-builder /src/target/release/libwren_lift.a   /usr/local/bin/libwren_lift.a

WORKDIR /build
COPY hatchfile main.wren ./
COPY lib    ./lib
COPY views  ./views
COPY public ./public
COPY content ./content

# Resolve [dependencies] from the registry, fetch each transitive
# `.hatch` bundle, and emit a self-contained `site.hatch`. Same
# step as the previous interpreter-based image.
RUN hatch build . --out site.hatch

# AOT-compile the bundle into a standalone native executable.
# Produces `./site` — embeds the WrenLift runtime, every reachable
# module's lowered code, GC + stack-map metadata, and the bundled
# Wren source the AOT bootstrap re-installs at startup. No
# interpreter dispatch on the hot path; AOT GC is on by default
# (`WLIFT_AOT_GC=0` is the emergency opt-out).
RUN wlift --aot ./site ./site.hatch

# ---------------------------------------------------------------
FROM debian:trixie-slim AS runtime

# `curl` lives here because `lib/catalog.wren` shells out to it
# for the GitHub-hosted index.toml refresh. `ca-certificates`
# makes the HTTPS handshake trustable.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
# The AOT binary is fully self-contained — no `wlift`, no
# `site.hatch`, no module-init dance at startup. `views/`,
# `content/`, and `public/` ride alongside because the site reads
# them from disk at request time:
#
#   * `views/<name>.html`   — `FnLoader` template lookup
#   * `content/<slug>.md`   — guide / blog markdown
#   * `public/assets/...`   — `Static.serve` middleware
COPY --from=bundle /build/site     ./site
COPY --from=bundle /build/views    ./views
COPY --from=bundle /build/content  ./content
COPY --from=bundle /build/public   ./public

ENV PORT=3000
EXPOSE 3000

# Direct AOT-binary invocation. No interpreter, no bundle parse.
CMD ["./site"]
