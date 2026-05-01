# Introduction

Hatch is the package manager + framework ecosystem for the [Wren](https://wren.io) scripting language, running on the [WrenLift](https://wrenlift.com) runtime. It gives you `hatch add @hatch:foo`-style dependency management, a `.hatch` bundle format that ships native plugins inside your code, and a curated standard library covering everything from JSON to GPU.

If you've reached for a Python `requirements.txt` or a Node `package.json`, the shape will feel familiar. Wren just keeps the surface lean enough to read in one sitting.

## Why bother

Wren by itself is a tiny embeddable language. WrenLift makes it portable: same Wren source runs on x86_64 macOS / Linux, aarch64 Apple Silicon, and `wasm32-unknown-unknown` in the browser, all out of one runtime. Hatch makes it shippable: versioned packages, native-code plugins that follow the runtime to whichever target is loading them, and a runnable single-file artifact.

```wren
import "@hatch:http" for Http
import "@hatch:json" for JSON

var res = Http.get("https://api.wrenlift.com/status")
if (res.ok) {
  System.print("build: %(JSON.parse(res.body)["build"])")
}
```

Three lines of imports: `@hatch:http` brings TLS, redirects, and streaming bodies; `@hatch:json` brings RFC-compliant parse + encode; and the runtime brings `Fiber`. None of them ship in plain Wren.

> **Tip: Built on familiar foundations**
> The package format is a TOML hatchfile + a list of Wren modules + an optional native dylib per platform, zipped into a single `.hatch` file. The CLI is one binary written in Rust. The runtime is one binary written in Rust. Everything composes through file-system paths and HTTP — no daemons, no central servers you have to keep running.

## What you get

- **Versioned dependencies.** `hatch add @hatch:web` records `@hatch:web = "0.1.3"` in your hatchfile; `hatch run` resolves the graph, downloads any missing bundles into `~/.hatch/cache`, and runs your entry module. SemVer-ish pinning, lockfile by request.
- **Native plugins, transparently.** A package can ship a Rust `cdylib` for performance-critical paths (`@hatch:sqlite`, `@hatch:gpu`, `@hatch:image`) and the runtime loads the right `.dylib` / `.so` / `.dll` for the host without you thinking about it.
- **A standard library.** ~40 packages under the `@hatch:*` scope cover networking (`http`, `socket`, `url`), data (`json`, `toml`, `csv`, `regex`, `sqlite`), system (`fs`, `os`, `proc`, `time`), graphics (`gpu`, `window`, `audio`, `image`, `physics`), framework (`web`, `template`, `ecs`, `game`), and devtools (`test`, `assert`, `fmt`, `log`).
- **A test runner.** `hatch test` walks every `*.spec.wren` in your workspace, runs them under the interpreter, and aggregates pass/fail. Spec deps (the test runner, assertion lib) install into the workspace but never ship in published bundles.

## How it fits together

```
your-project/
  hatchfile              # name, version, deps
  main.wren              # entry module (or whatever you set as `entry`)
  lib/                   # additional modules
  *.spec.wren            # tests, run via `hatch test`
  ~/.hatch/cache/        # downloaded packages, shared across projects
```

You write Wren. The hatchfile declares dependencies. `hatch run` builds + executes; `hatch build` produces a single `.hatch` artifact you can ship; `hatch publish` pushes it to the catalog so other people can `hatch add` it.

## Where to next

- [Install & setup](/guides/install): get the `wlift` and `hatch` binaries, run your first project.
- [The hatchfile](/guides/hatchfile): schema reference for every field.
- [CLI cheatsheet](/guides/cli): every `hatch <command>` invocation, what it does.
- [Authoring docs](/guides/authoring): how to write `///` comments that show up nicely on this site.
- [Packages](/docs): browse the registry; click any package for its README + auto-generated API reference.
