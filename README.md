<p align="center">
<img style="display: block;" src="logo.png" alt="hatch Logo" width="250"/>
</p>

<h1 align="center">Hatch</h1>

<p align="center">
The ecosystem for the <a href="https://wren.io">Wren</a> scripting language, powered by the <a href="https://github.com/wrenlift/WrenLift">WrenLift</a> runtime.
</p>

<p align="center">
<a href="https://github.com/wrenlift/hatch/actions/workflows/ci.yml"><img src="https://github.com/wrenlift/hatch/actions/workflows/ci.yml/badge.svg" alt="CI"/></a>
<img src="https://img.shields.io/badge/language-Rust-orange?logo=rust" alt="Rust"/>
<img src="https://img.shields.io/badge/edition-2021-blue" alt="Rust 2021"/>
<img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"/>
<img src="https://img.shields.io/badge/version-0.1.0-blue" alt="Version 0.1.0"/>
<a href="https://github.com/wrenlift/WrenLift"><img src="https://img.shields.io/badge/powered_by-WrenLift-2563eb" alt="Powered by WrenLift"/></a>
</p>

---

## Wren, without a host

Standard Wren is **embedding-first**. You link `libwren` into a C
or C++ application — a game, a level editor, a plugin host — and
run scripts from inside it. The canonical Wren project looks like
a chunk of C that loads a `.wren` file and calls into it. The
host owns the binary; Wren owns the fragments the host chooses
to expose.

**Hatch flips that.** With Hatch + WrenLift, the Wren code is
the program. You scaffold a project, you build it, you run it —
no host, no FFI glue, no C++ bindings. A `.hatch` file is the
thing you distribute, the way a `.jar` or `.pex` or `.exe` is. If
you've been writing Wren by embedding it into someone else's
application, Hatch is the permission to stop.

## What Hatch gives you

- **Package format.** A `.hatch` is a single, zstd-compressed,
  self-describing artifact that bundles compiled bytecode, a
  manifest, resources, and (soon) platform-native libraries. One
  file per library, one file per application, reproducible
  between machines.
- **Workflow.** `hatch init → hatch build → hatch run` is the
  full local loop: scaffold a project, compile it, execute it.
  No configuration beyond a `hatchfile` at the project root.
- **Dependencies.** Libraries declare their peers in
  `[dependencies]`; `hatch tidy` will resolve the graph, pin
  exact versions in a `hatchfile.lock`, and cache the resolved
  artifacts. Shape matches `go mod` / `cargo`.
- **Registry.** `hatch publish` / `hatch install` will push and
  fetch hatches from a shared index, with content hashes and
  (later) signatures verified on download.
- **Standard library.** The `packages/` tree in this repo is the
  canonical source of the official hatches (`std`, `http`, `json`,
  `test`, …) that every Wren workspace can lean on.

## Quickstart

```sh
hatch init my-app
cd my-app
hatch run
```

That's a real standalone Wren program, running on WrenLift. No C
project, no build system, no host harness.

The rest of the `hatch` surface — `add`, `remove`, `tidy`, `get`,
`publish` — is stubbed today with a roadmap message so the
planned ergonomics are visible while the resolver and registry
client ship.

## Workspace concept

A **wrenlift workspace** is any directory with a `hatchfile` at
its root:

```toml
name = "my-app"
version = "0.1.0"
entry = "main"

modules = ["util", "main"]

# [dependencies]
# std  = "0.3"
# http = { version = "0.1", features = ["tls"] }
```

Every `hatch` verb reads from that file. The workflow is the
same whether you're writing a one-file script, a multi-module
library, or an application that pulls in published hatches.

## Commands today

- `hatch init [DIR]` — scaffold a `hatchfile` + `main.wren`.
- `hatch build [DIR]` — pack the workspace into a `.hatch`.
- `hatch run [TARGET] [--with PKG]` — build + run, or run a
  pre-built `.hatch`. `--with` preloads dependency hatches.
- `hatch inspect PACKAGE` — print manifest + section listing.

## Dev setup

`cli` depends on WrenLift directly from its git repository, so a
fresh clone of this repo builds on its own:

```toml
wren_lift = { git = "https://github.com/wrenlift/WrenLift.git", default-features = false, features = ["cranelift"] }
```

Pin to a commit or tag for reproducible builds once WrenLift
starts cutting releases.

## License

MIT.
