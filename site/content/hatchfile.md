A `hatchfile` is the TOML manifest at the root of every workspace. It declares a package's identity, what it depends on, and any native libraries it needs to load. The same file ships inside the published `.hatch` artifact verbatim, so the loader and the docs site read what you wrote.

The file is parsed by `serde` against the `Manifest` struct in `src/hatch.rs`. Anything not listed below is ignored on read. Handy for forward-compat experiments, but don't rely on it.

## A complete example

```toml
name        = "my-app"
version     = "0.1.0"
entry       = "main"
description = "A short, one-line summary."
homepage    = "https://hatch.wrenlift.com/docs/my-app"
readme      = "README.md"

modules = ["util", "main"]

[dependencies]
"@hatch:web"  = "0.1.3"
"@hatch:json" = "0.1.2"

[spec-dependencies]
"@hatch:test"   = { path = "../hatch-test" }
"@hatch:assert" = { path = "../hatch-assert" }

[native_libs]
my_lib = { macos = "libs/libmy_lib.dylib", linux = "libs/libmy_lib.so", windows = "libs/my_lib.dll" }

native_search_paths = ["libs"]

[plugin_source]
repo    = "https://github.com/me/my-lib"
rev     = "abc1234"
library = "my_lib"
```

That's the full surface for most packages. Walk through each block below.

## Top-level fields

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `name` | string | yes | Package identifier. Catalog entries use the `@scope:name` shape (e.g. `@hatch:json`); your own packages can be bare names. |
| `version` | string | yes | SemVer-ish. The catalog enforces strict `MAJOR.MINOR.PATCH` on publish; local-only packages can be looser. |
| `entry` | string | yes | Module name to run as the program's top-level. `entry = "main"` runs the bytecode compiled from `main.wren`. |
| `description` | string | no | One-line summary. Surfaces in `hatch find` output and on the docs page header. Strongly encouraged. |
| `homepage` | string | no | Public landing page URL. The catalog falls back to the `git` URL when omitted. |
| `readme` | string | no | Either an absolute URL (used verbatim by the docs renderer) or a path relative to the repo root (resolved against `git` via the host's `raw` URL pattern). Defaults to `README.md`. |
| `modules` | array of strings | no | Ordered list of module names. The loader installs them in this order so a module's imports resolve against already-loaded peers. Empty / omitted means `hatch build` discovers every `.wren` automatically. |
| `target` | string | no | Triple this hatch was built for. Mismatched bundles refuse to load. See "Targets" below. |

## `[dependencies]`

Every entry maps a name to one of four shapes:

```toml
[dependencies]
"@hatch:json" = "0.1.2"                                       # 1. version pin
counter       = { path = "../counter" }                       # 2. local path
mylib         = { git = "https://github.com/alice/mylib.git", # 3. git ref
                  tag = "v0.3.0" }
otherlib      = { url = "https://cdn.example.com/x.hatch" }   # 4. direct URL
```

| Shape | Resolves through | Notes |
|-------|------------------|-------|
| Version | the registry release cache | `hatch install <name>@<version>` populates `~/.hatch/cache`. The default catalog is the `@hatch:*` registry; override via `WLIFT_HATCH_REGISTRY`. |
| `path` | filesystem at build time | Workspace-relative. Recursively built and merged into the enclosing hatch. Optional `version = "..."` is informational. |
| `git` | a shallow clone of the repo | Pin via `tag`, `rev`, or `branch`. `rev` is most reproducible. Optional `url = "..."` overrides the browser-side resolver's release-asset guess (useful for self-hosted forges). |
| `url` | direct HTTP fetch | Browser resolver only. The host CLI errors on this; it has no way to recursively resolve a hatch's transitive deps from a single artifact URL. |

## `[spec-dependencies]`

Same shape as `[dependencies]`. The difference is they're only installed when `hatch test` runs `*.spec.wren` files. They never ship in the published bundle, so consumers don't pay for your test framework's transitive deps.

```toml
[spec-dependencies]
"@hatch:test"   = "0.1"
"@hatch:assert" = "0.1"
```

## `[native_libs]`

Maps a logical library name to where the loader can find its `.dylib` / `.so` / `.dll`. The key is what a Wren `#!native = "..."` attribute resolves against.

Two value shapes:

```toml
[native_libs]
libssl  = "/usr/lib/libssl.dylib"            # bare path
sqlite3 = { macos = "libs/libsqlite3.dylib", # per-platform map
            linux = "libs/libsqlite3.so",
            windows = "libs/sqlite3.dll" }
zlib    = { "macos-arm64"  = "libs/arm64/libz.dylib",
            "macos-x86_64" = "libs/x86_64/libz.dylib",
            any            = "libz" }        # ambient OS lookup fallback
```

Recognized keys, in resolution order:

| Key | Matches |
|-----|---------|
| `<os>-<arch>` | Most specific. `macos-arm64`, `linux-x86_64`, `windows-x86_64`. |
| `<os>` | OS bucket. `macos`, `linux`, `windows`, `freebsd`. |
| `any` | Catch-all when no specific entry matches. |
| `path` | Legacy alias for `any`. New code should use `any`. |

Architecture names are short: `arm64` (not `aarch64`), `x86_64`, `x86`. OS names match `std::env::consts::OS`.

> **Tip: Bundle every platform's binary**
> The publish path packs every relative path declared under `[native_libs]` into the bundle. That means a Mac contributor can `hatch install` a package whose CI built dylibs on Linux + macOS + Windows, and the loader will find a Mach-O at runtime. Absolute paths (`/usr/lib/...`) are skipped; those are system references, not bundleable assets.

## `native_search_paths`

```toml
native_search_paths = ["libs", "/opt/homebrew/lib"]
```

Extra directories scanned ahead of the OS loader's ambient search when resolving `#!native` references. Workspace-relative or absolute. Useful when you want the bare-name shorthand (`libssl = "libssl"`) to find a local copy without `LD_LIBRARY_PATH` gymnastics.

## `[plugin_source]`

For packages whose native library is built from an out-of-tree Rust `cdylib`. CI consumes this; the runtime never reads it.

```toml
[plugin_source]
repo    = "https://github.com/wrenlift/WrenLift.git"
rev     = "29ac35a"
library = "wlift_sqlite"
```

| Field | Notes |
|-------|-------|
| `repo` | Git URL. Optional when `url` is set. |
| `rev` | Commit SHA. Most reproducible. |
| `tag` | Alternative to `rev`. CI errors when neither is given alongside `repo`. |
| `library` | Name of the Cargo package (or equivalent) inside the source tree. The older `crate = "..."` spelling is accepted as a serde alias. |
| `url` | Direct download URL for a pre-built artifact. CI / wasm runtimes that can fetch HTTP pull this verbatim instead of cloning. The host CLI never reads this; `hatch publish` ignores it. |

The hatch CI workflow in the package's repo: clone `repo` at `rev`/`tag`, `cargo build -p <library> --release` per platform, copy outputs into `libs/`, then publish.

## `target`

```toml
target = "wasm32"
```

Triple this hatch was built for. The loader checks the triple matches its own runtime; a mismatch refuses to load with `HatchError::WrongTarget`.

| Value | Matches |
|-------|---------|
| Concrete triple (`x86_64-apple-darwin`, `wasm32-unknown-unknown`, `wasm32-wasip1`) | Exact only. |
| `wasm32` | Family marker for any `wasm32-*` runtime. A single bundle works on both `unknown-unknown` and `wasip1`. |
| absent | "Host target". Preserves the pre-target-aware behavior. |

For `wasm32-*` targets the publish path skips packing host `.dylib` / `.so` bytes. Wasm runtimes use statically linked plugins (see `wlift_wasm`), so a wasm hatch's `[native_libs]` is treated as a *required* set the runtime must already carry, not a build-time bundle.

## Next

- [CLI cheatsheet](/guides/cli): turn the hatchfile into running code.
- [Authoring docs](/guides/authoring): how the hatchfile's `description` + `readme` feed the docs site.
