Hatch ships as two binaries: `wlift` (the WrenLift runtime, which runs `.wren` files, `.wlbc` caches, and `.hatch` bundles) and `hatch` (the workspace front-end: scaffold, build, publish, install). You want both. They live next to each other on disk and `hatch` shells out to `wlift` for `hatch test` and `hatch web serve`.

## Install via the script

The fast path:

```sh
curl -fsSL https://wrenlift.com/install.sh | sh
```

This pulls the latest tagged release for your platform (macOS arm64/x86_64, Linux x86_64/aarch64) and drops both binaries in `$HOME/.local/bin`. Make sure that's on your `PATH`.

Two knobs worth knowing:

| Variable | Default | Effect |
|----------|---------|--------|
| `WLIFT_VERSION` | latest tag | Pin to a specific release, e.g. `WLIFT_VERSION=v0.2.0`. |
| `INSTALL_DIR`   | `$HOME/.local/bin` | Where the binaries land. Use `/usr/local/bin` for a system-wide install (the script won't `sudo` for you; run with `sudo sh` or do the copy yourself). |

```sh
# Pin to a release, system-wide
curl -fsSL https://wrenlift.com/install.sh \
  | WLIFT_VERSION=v0.2.0 INSTALL_DIR=/usr/local/bin sudo sh
```

Windows isn't covered by the script. Grab the binaries from [GitHub Releases](https://github.com/wrenlift/WrenLift/releases) and drop them on your `PATH`.

## Install from source

For contributors and people who like building things:

```sh
cargo install --git https://github.com/wrenlift/WrenLift wren_lift --bins --locked
```

This builds release versions of both binaries from `main`. The first build takes a few minutes (zstd, ariadne, cranelift). Subsequent rebuilds are incremental.

## Verify

```sh
wlift --version
hatch --version
```

Both should print a version string. If `command not found`, your install dir isn't on `PATH`. Add it to your shell rc:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

## Scaffold a project

```sh
hatch init my-app
cd my-app
```

That writes a minimal `hatchfile` and a `main.wren` stub:

```
my-app/
  hatchfile        # name, version, entry, deps
  main.wren        # entry module
```

The default `main.wren` prints "hello from my-app". Pass `--template web` instead for a `@hatch:web` starter (router, Css helpers, demo route).

## Run it

```sh
hatch run
```

`hatch run` with no argument builds the current workspace into an in-memory `.hatch` and runs it. Pass an explicit path to run an existing workspace or pre-built artifact:

```sh
hatch run ./other-project    # build + run another workspace
hatch run my-app.hatch       # run a built bundle
```

You should see `hello from my-app` on stdout.

## Add a dependency

Two ways. The hand-edit path stays honest about what's going on:

```toml
# hatchfile
[dependencies]
"@hatch:json" = "0.1.2"
```

Then:

```sh
hatch install
hatch run
```

`hatch install` (no arg) walks every entry in `[dependencies]` and downloads any missing bundle into `~/.hatch/cache`. `hatch run` resolves the graph and executes.

Or pin + install in one step:

```sh
hatch install @hatch:json@0.1.2
```

This records `"@hatch:json" = "0.1.2"` in your hatchfile and pulls the bundle.

> **Tip: `hatch add` is a stub today**
> The `hatch add` verb is a placeholder; it prints "not yet implemented" and exits non-zero. Use `hatch install <name>@<version>` until the resolver lands.

## Editor setup

There's no official LSP yet. Two interim options:

- **Per-package API JSON.** `hatch docs <workspace>` emits the same `Vec<ModuleDoc>` JSON the docs site renders — pipe it into your editor of choice for completion / hover.
- **Per-module HTML.** `wlift --docs out/ <workspace>` writes a static doc tree under `out/` (one HTML file per module).

Both consume `///` decl docs and `//!` (or file-leading `//`) module docs. See [Authoring docs](/guides/authoring) for the conventions.

## Next

- [The hatchfile](/guides/hatchfile): every TOML field, what it does.
- [CLI cheatsheet](/guides/cli): every `hatch` and `wlift` invocation.
