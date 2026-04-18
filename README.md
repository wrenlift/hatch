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

**Hatch** is what Wren developers reach for every day. It's the
package format, the workflow tool, and the official library set
that turn WrenLift from a runtime into a language you can ship
with. If you write Wren, you work through Hatch:

- **Package format.** A `.hatch` is a single, zstd-compressed,
  self-describing artifact that bundles compiled bytecode, a
  manifest, resources, and (eventually) platform-native libraries.
  One file per library, one file per application, reproducible
  between machines.
- **Workflow.** `hatch init → hatch build → hatch run` is the full
  local loop: scaffold a project, compile it, execute it. No
  configuration beyond a `hatchfile` at the project root.
- **Dependencies.** Libraries declare their peers in
  `[dependencies]`; `hatch tidy` will resolve the graph, pin exact
  versions in a `hatchfile.lock`, and cache the resolved artifacts.
  Think `go mod` or `cargo` — the shape will be familiar.
- **Registry.** `hatch publish` / `hatch install` will push and
  fetch hatches from a shared index, with content hashes and (later)
  signatures verified on download.
- **Standard library.** The `packages/` tree in this repo is the
  canonical source of the official hatches (`std`, `http`, `json`,
  `test`, …) that every Wren workspace can lean on. They build,
  version, and ship like any other hatch.

## Quickstart

```sh
hatch init my-app
cd my-app
hatch run
```

This works today. The rest of the `hatch` surface — `add`,
`remove`, `tidy`, `get`, `publish` — is stubbed with a roadmap
message so the planned ergonomics are visible while the resolver
and registry client ship.

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

Every `hatch` verb reads from that file. Projects can be a single
`main.wren`, a library with a dozen modules, or an application
that depends on both local and published hatches — the workflow
doesn't change.

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

Pin to a commit or tag for reproducible builds once WrenLift starts
cutting releases.

## License

MIT.
