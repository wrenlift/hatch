Two binaries, one ecosystem. `hatch` is the workspace front-end (scaffold, build, publish, install). `wlift` is the runtime that actually executes Wren; `hatch test` and `hatch web serve` shell out to it. Both expose enough surface that you'll occasionally want both.

This page is a reference, not a tutorial. For a walk-through, start with [Install & setup](/guides/install).

## `hatch init`

```sh
hatch init [DIR] [--name NAME] [--template KIND]
```

Scaffold a new workspace. `DIR` defaults to `.`; `--name` overrides the auto-detected package name (the directory's basename); `--template` picks a starter:

| Template | Result |
|----------|--------|
| `bare` (default) | minimal `hatchfile` + `main.wren` printing `hello from <name>`. |
| `web` | `@hatch:web` app: `App.new()`, two demo routes, Css helpers, `public/`, `.gitignore`. |

Unknown templates fall back to `bare` with a warning. Dedicated `game` / `cli` scaffolds land later.

```sh
hatch init mysite --template web
hatch init mylib                  # → bare
```

## `hatch test`

```sh
hatch test [DIR]
```

Walks every `*.spec.wren` under `DIR` (default `.`), runs each through `wlift --mode interpreter`, and aggregates the `ok: N/M passed` lines into a final summary. Exits non-zero if any spec failed.

```sh
hatch test                  # current workspace
hatch test packages/foo     # one sub-tree
```

The runner ignores `target/`, `node_modules/`, and dotted directories.

## `hatch web serve`

```sh
hatch web serve [DIR]
```

Watch the workspace and reload on save. Spawns `wlift --mode interpreter --step-limit 0 --watch <entry>.wren` and polls source mtimes every 500ms. On any change, sends `SIGUSR1` to the child. The runtime reloads modified modules in-process at the next safepoint, no respawn, no lost state.

If the runtime exits hard (compile error, panic) the supervisor waits for the next save and respawns. Ctrl-C tears down both via the foreground process group.

> **Tip: Unix-only signal path**
> SIGUSR1 doesn't exist on Windows. The dev loop's signalling path is no-op'd there, so saves won't trigger reloads. Use a Unix dev box for now.

## `hatch web generate`

```sh
hatch web generate KIND NAME [--dir DIR]
```

Stub generators for an existing `@hatch:web` workspace. `KIND` is one of:

| Kind | Output |
|------|--------|
| `route` | `routes/<name>.wren`: class with GET / POST handlers. |
| `form` | `forms/<name>.wren`: `Form` schema with example fields. |
| `template` | `templates/<name>.wren`: `Template.parse(...)` stub. |

```sh
hatch web generate route posts
hatch web generate form login
```

## `hatch build`

```sh
hatch build [DIR] [-o OUT]
```

Compile the workspace into a single `.hatch` bundle. `DIR` defaults to `.`; `-o` / `--out` overrides the output path. Without `--out`, the artifact lands at `<name>.hatch` in the workspace root.

```sh
hatch build
hatch build -o dist/my-app.hatch
```

## `hatch inspect`

```sh
hatch inspect PACKAGE
```

Print a `.hatch` file's manifest + section listing without running it. Useful for debugging "what's actually in this bundle?". Shows every section's kind, byte length, and name.

```sh
hatch inspect my-app.hatch
```

## `hatch docs`

```sh
hatch docs [TARGET] [-o OUT]
```

Emit the package's API documentation as JSON: one `ModuleDoc` per `.wren` module, every class / member pulled from `///` doc comments. Same shape the publish path stuffs into the bundle's `Docs` section. `TARGET` may be either a workspace directory (live source) or an already-built `.hatch` (cached `Docs` section). Output goes to stdout for piping; `-o` writes a file.

```sh
hatch docs                       # current workspace → stdout
hatch docs my-app.hatch -o api.json
```

This is what feeds the API-reference renderer at `hatch.wrenlift.com/docs/<package>`.

## `hatch run`

```sh
hatch run [TARGET] [--with PACKAGE]...
```

Run a workspace or a built `.hatch`. `TARGET` defaults to `.`; a directory builds in-memory then runs, a file path loads bytes directly. `--with` preloads a library hatch before the main package; repeat for multiple.

```sh
hatch run                                      # current workspace
hatch run my-app.hatch                         # pre-built bundle
hatch run app.hatch --with lib-a.hatch --with lib-b.hatch
```

`WLIFT_MODE=interpreter` forces the VM out of tiered into the pure interpreter, handy when a JIT regression bites. Other values keep the tiered default.

## `hatch install`

```sh
hatch install [PACKAGE] [-C DIR]
```

Pull a package from the registry into the local cache and record it under `[dependencies]`. Three flavours of input:

| Input | Behaviour |
|-------|-----------|
| `<name>@<version>` | Pinned. Caches that version, writes `name = "version"` into the hatchfile. |
| `<name>` | Looks up the version already declared in `[dependencies]`. Errors if absent. |
| (no arg) | Walks `[dependencies]`. Caches every version-pinned + git-pinned entry. Path deps need nothing. |

```sh
hatch install @hatch:json@0.1.2
hatch install                              # restore from hatchfile
hatch install -C packages/foo @hatch:web   # different workspace
```

## `hatch add` / `hatch remove` / `hatch tidy` / `hatch get`

These are placeholders today; they print "not yet implemented" and exit non-zero. Use `hatch install <name>@<version>` (and hand-edit the hatchfile to remove a dep) until the resolver lands. They're listed here so the planned shape is visible:

| Command | Planned behaviour |
|---------|-------------------|
| `hatch add NAME [VERSION]` | Resolve, cache, and record. Like `hatch install` but with full SemVer constraint resolution. |
| `hatch remove NAME` | Drop a dep, prune unused cache entries. |
| `hatch tidy` | Refresh `hatchfile.lock`: resolve every dep transitively, prune unused. |
| `hatch get NAME` | Cache without modifying the hatchfile. |

## `hatch publish`

```sh
hatch publish [-C DIR] [--git URL]
```

Register the workspace's package with the hatch catalog. Reads `name` + `version` + `description` + `readme` from the hatchfile; publishes them alongside a git URL so other people can `hatch find` and pin.

The git URL: `--git` wins; otherwise the workspace's `origin` remote is probed. If neither is available, publish refuses. A catalog entry without a git URL is useless to consumers.

Requires `hatch login` first. The JWT is refreshed quietly if it's near expiry.

```sh
hatch publish
hatch publish --git https://github.com/me/my-lib.git
```

## `hatch find`

```sh
hatch find NAME[@VERSION]
```

Look up a package in the catalog. With a bare name, lists every published version (newest first) plus owner / description / git URL. With `<name>@<version>`, narrows to one row.

Read-only. Works without `hatch login`.

```sh
hatch find @hatch:json
hatch find @hatch:json@0.1.2
```

## `hatch login` / `hatch logout`

```sh
hatch login [--token JWT]
hatch logout
```

Authenticate against the hatch service. Full GitHub OAuth device flow lands in a follow-up; for now `--token` accepts a pre-minted JWT. `--token -` reads from stdin so the token never appears in `argv` (visible via `ps`).

`hatch logout` drops the stored credentials file. Safe to run anytime.

```sh
hatch login --token "$JWT"
hatch login --token -    < jwt.txt
hatch logout
```

# `wlift`

The runtime. Runs a single `.wren` file, a `.wlbc` cache, or a `.hatch` bundle.

## `wlift FILE`

```sh
wlift main.wren
```

Execute a Wren file under the default tiered VM. Omit `FILE` to drop into the REPL.

## `--mode {interpreter,tiered,jit}`

```sh
wlift --mode interpreter main.wren
wlift --mode jit main.wren
```

Pick the execution strategy:

| Mode | Behaviour |
|------|-----------|
| `tiered` (default) | Start in the bytecode interpreter, JIT-compile hot functions in the background. Best wall-clock on long-running workloads. |
| `interpreter` | Pure walking interpreter. Slower but trivially debuggable; `hatch test` and `hatch web serve` use this. |
| `jit` | AOT-ish; compile every function before running. Useful for measuring peak JIT throughput; not the right default. |

## `--target {native,wasm}`

Codegen backend. `native` is the host CPU (x86_64 / aarch64 via Cranelift). `wasm` produces a `.wasm` module; pair with `--output`.

## `--build OUT_PATH`

```sh
wlift --build main.wlbc main.wren
```

Compile the source into a portable `.wlbc` bytecode cache and exit. Subsequent runs of `wlift main.wlbc` skip parse / sema / MIR-build / optimize.

## `--bundle OUT_PATH [--bundle-target TRIPLE]`

```sh
wlift --bundle out.hatch ./my-app
wlift --bundle out.hatch --bundle-target wasm32 ./my-app
```

Compile a source tree into a `.hatch` bundle and exit. The positional `FILE` argument is treated as the workspace root. If a `hatchfile` is present it's used; otherwise a minimal manifest is synthesised. `--bundle-target` overrides the target triple. Pass `wasm32` (family marker) or a concrete `wasm32-*` triple to produce a wasm-loadable hatch.

`hatch build` is the higher-level path; `wlift --bundle` is the bare-runtime equivalent.

## `--inspect`

```sh
wlift --inspect my-app.hatch
```

Print a hatch's manifest + section listing without running it. Same output as `hatch inspect`.

## `--docs OUT_DIR`

```sh
wlift --docs out/ ./my-app
```

Generate static HTML documentation for a source tree. One file per module under `OUT_DIR`, plus an `index.html` listing every module. Doc bodies come from `///` and `//!` comments, rendered as CommonMark.

This is the offline counterpart to `hatch docs` (which emits JSON).

## `--watch`

```sh
wlift --watch main.wren
```

Install a `SIGUSR1` handler that reloads any user module whose mtime advanced. Designed for the `hatch web serve` supervisor; manual `kill -USR1 <pid>` works too.

## `--step-limit N`

```sh
wlift --step-limit 0 main.wren
```

Maximum interpreter steps before aborting. The default is 1B (interpreter) / 10B (tiered), enough for ~10-30 minutes of polling-loop instructions. Pass `0` to disable entirely. Recommended for long-running servers.

## `--gc {generational,arena,marksweep}`

GC strategy. Generational nursery + old-gen mark-sweep is the default and the right choice for almost everything. `arena` is allocate-only / free-on-drop, best for short-lived scripts and benchmarks. `marksweep` is non-generational; useful for differential testing.

## Other flags

`--dump-tokens`, `--dump-ast`, `--dump-mir`, `--dump-opt`, `--dump-asm`, `--no-opt`, `--gc-stats`, `--tree-shake-stats`, `--opt-threshold`. Compiler-internals introspection, useful when you're debugging a regression, not for daily use.

# Common flows

**Publish a package.**

```sh
hatch login --token "$JWT"
hatch build
hatch publish
```

**Run a built bundle.**

```sh
hatch run dist/my-app.hatch
# or:
wlift dist/my-app.hatch
```

**Hot-reload a web app.**

```sh
hatch init mysite --template web
cd mysite
hatch web serve
# edit main.wren; saves trigger SIGUSR1, runtime reloads the module
```

**Pin every dep, restore on a fresh clone.**

```sh
# in CI:
hatch install               # walks [dependencies], populates ~/.hatch/cache
hatch test
hatch build
```

**Bundle for wasm.**

```sh
wlift --bundle out.hatch --bundle-target wasm32 ./my-app
```

The wasm runtime (browser worker / Node) loads the same `.hatch` and statically-linked plugins satisfy the manifest's `[native_libs]` requirements.
