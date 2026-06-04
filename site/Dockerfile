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

# wren_lift source revision. Accepts a tag (`v0.1.17`), a branch
# (`main`), or a commit SHA. Pinned to a SHA here so the Docker
# layer cache invalidates deterministically when we move to a
# newer wren_lift — `git clone --branch main` would reuse a
# stale cached clone even after upstream advanced.
#
# Required floor for AOT stability on Linux:
#   - 8979286 — drop USER_VA_LIMIT writeback guard (closes the
#     Linux-aarch64 stack-slot stale-pointer class)
#   - 8f4267c — declare SM-transform fresh ValueIds as stack-map
#     roots (closes the Mac-and-Linux SM-load gap)
#   - ecb8345 — fmt/clippy/doc cleanups + cranelift patch
#     retargeted at upstream wasmtime main
#   - c4f8327 — CI clippy fix for wasm32 no-default-features build
#   - 068ef3a — explicit System global_allocator + krio u64 fast
#     path (kills the tight-yield-loop leak on Linux glibc)
#   - c4dac8f — malloc_trim(0) at end of minor GC on Linux
#   - d2db30f — String.intern foreign method
#   - 7397546 — auto-intern short strings (≤32 bytes) in
#     new_string; site peak RSS 768 → 349 MB under the 200-req
#     burst, memory now shrinks between batches instead of
#     climbing monotonically to the OOM cap
#   - 3326d00 — AOT picks up host CPU features via
#     cranelift_native::builder (AVX2 + BMI1/2 on fly's
#     Skylake Xeons instead of base SSE2); perf-only, no
#     functional change
# Flip to a `v…` tag once a release ships these.
ARG WLIFT_VERSION=88e6b5df650bde68c0ffaadee0104c225144085a
ARG WLIFT_REPO=https://github.com/wrenlift/WrenLift.git

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git ca-certificates pkg-config cmake build-essential \
    && rm -rf /var/lib/apt/lists/*

# Shallow fetch by ref — works for tags, branches, and SHAs.
# GitHub allows `git fetch --depth=1 origin <sha>` by default
# (uploadpack.allowReachableSHA1InWant = true server-side), so
# we don't have to clone the full history just to checkout a
# pinned commit.
WORKDIR /src
RUN git init . \
    && git remote add origin ${WLIFT_REPO} \
    && git fetch --depth 1 origin ${WLIFT_VERSION} \
    && git checkout FETCH_HEAD

# `--features aot` pulls in the Cranelift object-emitter + the
# AOT bootstrap shim. `--lib` is needed alongside the bins so
# the lib crate's `staticlib` crate-type produces
# `libwren_lift.a` — `wlift --aot` looks for it next to its own
# binary, and a plain `--bin` build only emits the rlib the
# bins need to link against. The bundle stage copies all three.
RUN cargo build --release --features aot --bin wlift --bin hatch --lib

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

# Seed the catalog mirror so `Catalog.boot()` lands a populated
# table on first request instead of an empty one. `Catalog.
# fetchAndParse_` prefers `./index.toml` over the network fetch
# (see catalog.wren's `LOCAL_INDEX_`), so dropping the
# sync-index workflow's published copy alongside the binary
# means cold boots don't depend on the GitHub raw endpoint
# being reachable from the deploy region. The background
# refresh loop still pulls fresh upstream data every couple
# hours; this just guarantees the boot path has data to seed
# from.
#
# Bake-time fetch (not COPY) because the canonical mirror lives
# in the repo root (`hatch/index.toml`), one level above the
# site Dockerfile's build context, and we don't want to change
# the context root or move the file.
RUN curl --fail --silent --show-error --location \
        --output /app/index.toml \
        https://raw.githubusercontent.com/wrenlift/hatch/main/index.toml \
    && wc -c /app/index.toml

ENV PORT=3000
EXPOSE 3000

# Direct AOT-binary invocation. No interpreter, no bundle parse.
CMD ["./site"]
