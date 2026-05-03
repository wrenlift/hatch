<p align="center">
<img style="display: block;" src="hatch_logo_flat.png" alt="hatch Logo" width="250"/>
</p>

<h1 align="center">Hatch</h1>

<p align="center">
Build, run, and ship <a href="https://wren.io">Wren</a> programs as standalone projects. Powered by the <a href="https://github.com/wrenlift/WrenLift">WrenLift</a> runtime.
</p>

<p align="center">
<a href="https://github.com/wrenlift/hatch/actions/workflows/regression.yml"><img src="https://img.shields.io/github/actions/workflow/status/wrenlift/hatch/regression.yml?branch=main&label=Regression&logo=data:image/svg%2Bxml;base64,PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPHN2ZyB2ZXJzaW9uPSIxLjEiIHZpZXdCb3g9IjIxOSAxODEgODE2IDg2MSIgd2lkdGg9IjgxNiIgaGVpZ2h0PSI4NjEiIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+CjxwYXRoIHRyYW5zZm9ybT0idHJhbnNsYXRlKDg4MiwxODEpIiBkPSJtMCAwaDE5bDIyIDIgMjUgNSAyMCA3IDE1IDggMTQgMTAgMTEgMTAgMTAgMTMgNyAxMiA1IDEzIDQgMTcgMSA2djM3bC04IDU4LTEzIDg3LTEzIDkzLTEzIDEwOC03IDcwLTUgNjV2MzhsNyA4IDEwIDExIDggMTMgNiAxNiAyIDggMSAxMHYxM2wtNCAyMC03IDE2LTggMTItOSAxMC04IDgtMTUgMTEtMTQgOC0yMCA5LTMzIDExLTMyIDctMjIgMy0xMSAxaC00MWwtMjMtMy0yMC01LTE5LTctMTctOS0xMy05LTExLTktOS05LTExLTE0LTExLTE5LTgtMjAtNS0xOS0yLTExLTEtMTF2LTIybDUtNDMgOS02NSA2LTQzLTIzIDUtNTUgMTEtMyAxLTEwIDY1LTYgNDgtMSAxNyA4IDEwIDggMTYgNSAxNiAxIDZ2MjVsLTQgMTYtNSAxMi03IDExLTkgMTEtNyA3LTE1IDExLTE0IDgtMjYgMTEtMjYgOC0yOSA2LTIwIDMtMTIgMWgtNDZsLTE4LTItMjUtNi0xNi02LTIxLTExLTEyLTktMTItMTEtOC05LTEyLTE4LTgtMTgtNS0xNi0zLTE1LTEtOXYtMjlsNC0zMSA3LTQ1IDE4LTExNCAxNC05NCAxNS0xMDcgMTAtNzQgMy0yMy05LTItMTYtOC0xMC04LTUtNS03LTgtOC0xNS00LTE0LTEtNnYtMjJsNC0xNiA1LTExIDYtMTEgOC0xMCA5LTEwIDExLTkgMTQtMTAgMTYtOSAxOS05IDI1LTkgMjgtOCAzNC03IDI4LTQgMjItMmgzOGwyNiAzIDIzIDUgMTcgNiAyMSAxMSAxMiA5IDEwIDkgMTEgMTQgOCAxNSA2IDE4IDMgMTd2MjZsLTQgMjgtMTQgODgtNCAyNCA2NS0xMyAzMy03aDNsMS0xMSAxMS02OXYtOGwtOS0xMy02LTE0LTMtMTZ2LTEzbDMtMTYgNS0xMiA2LTExIDktMTEgMTEtMTEgMTYtMTIgMTYtOSAxOS05IDI3LTkgMjEtNSAxOS0zeiIgZmlsbD0iI0ZERDE2OSIvPgo8cGF0aCB0cmFuc2Zvcm09InRyYW5zbGF0ZSg4ODIsMTgxKSIgZD0ibTAgMGgxOWwyMiAyIDI1IDUgMjAgNyAxNSA4IDE0IDEwIDExIDEwIDEwIDEzIDcgMTIgNSAxMyA0IDE3IDEgNnYzN2wtOCA1OC0xMyA4Ny0xMyA5My0xMyAxMDgtNyA3MC01IDY1djM4bDcgOCAxMCAxMSA4IDEzIDYgMTYgMiA4IDEgMTB2MTNsLTQgMjAtNyAxNi04IDEyLTkgMTAtOCA4LTE1IDExLTE0IDgtMjAgOS0zMyAxMS0zMiA3LTIyIDMtMTEgMWgtNDFsLTIzLTMtMjAtNS0xOS03LTE3LTktMTMtOS0xMS05LTktOS0xMS0xNC0xMS0xOS04LTIwLTUtMTktMi0xMS0xLTExdi0yMmw1LTQzIDktNjUgNi00My0yMyA1LTU1IDExLTMgMS0xMCA2NS02IDQ4LTEgMTcgOCAxMCA4IDE2IDUgMTYgMSA2djI1bC00IDE2LTUgMTItNyAxMS05IDExLTcgNy0xNSAxMS0xNCA4LTI2IDExLTI2IDgtMjkgNi0yMCAzLTEyIDFoLTQ2bC0xOC0yLTI1LTYtMTYtNi0yMS0xMS0xMi05LTEyLTExLTgtOS0xMi0xOC04LTE4LTUtMTYtMy0xNS0xLTl2LTI5bDQtMzEgNy00NSAxOC0xMTQgMTQtOTQgMTUtMTA3IDEwLTc0IDMtMjMtOS0yLTE2LTgtMTAtOC01LTUtNy04LTgtMTUtNC0xNC0xLTZ2LTIybDQtMTYgNS0xMSA2LTExIDgtMTAgOS0xMCAxMS05IDE0LTEwIDE2LTkgMTktOSAyNS05IDI4LTggMzQtNyAyOC00IDIyLTJoMzhsMjYgMyAyMyA1IDE3IDYgMjEgMTEgMTIgOSAxMCA5IDExIDE0IDggMTUgNiAxOCAzIDE3djI2bC00IDI4LTE0IDg4LTQgMjQgNjUtMTMgMzMtN2gzbDEtMTEgMTEtNjl2LThsLTktMTMtNi0xNC0zLTE2di0xM2wzLTE2IDUtMTIgNi0xMSA5LTExIDExLTExIDE2LTEyIDE2LTkgMTktOSAyNy05IDIxLTUgMTktM3ptLTcgNDctMjQgMy0yNSA2LTE5IDctMTcgOC0xMyA5LTEwIDktNyA4LTQgOC0xIDR2MTRsNSAxMCA4IDggNCAzaDJsMSA0djEybC05IDU3LTEzIDc3LTEyMyAyNS03NCAxNSA3LTQ4IDgtNTUgMTUtOTd2LTI1bC00LTE1LTUtMTAtOC0xMC0xMS05LTE2LTgtMTYtNS0xNi0zLTktMWgtNDJsLTI4IDMtMzMgNi0yNCA2LTI3IDktMTggOC0xNyA5LTEyIDktMTAgOS05IDEyLTQgMTJ2MTFsNCAxMSA4IDkgMTQgNyAyMSA0IDggNCA0IDUgMiA2djIxbC02IDQ4LTE4IDEzMS0xNSAxMDQtMTggMTE1LTEzIDgyLTIgMjB2MTNsMiAxNiA1IDE3IDkgMTcgMTIgMTQgMTAgOCAxNCA4IDE1IDYgMjUgNSAxMiAxaDIwbDI0LTIgMjUtNCAyNC02IDIwLTcgMTYtOCAxMC02IDExLTkgOC0xMCA0LTEwIDEtMTMtNC0xMy03LTktNi03LTQtMTAtMS01di0yOGw1LTQyIDktNjEgOC01MXYtM2w5LTEgMTYyLTMyIDktMi0zIDE3LTIwIDE0NC01IDM5LTEgMTF2MjFsMyAxOSA1IDE2IDEwIDE5IDExIDEzIDEwIDkgMTQgOSAxOSA4IDE3IDQgMTUgMmgzN2wyNS0zIDIzLTUgMjAtNiAyMS04IDE3LTkgMTItOSA2LTUgOS0xMiA0LTExIDEtOS0yLTEwLTUtMTAtMTEtMTEtNi01LTUtOC00LTE0LTEtN3YtNDNsNC01NiA3LTczIDgtNzEgOS02OSAxMy05MCAyMC0xMzB2LTI0bC00LTE2LTYtMTEtOS0xMC04LTctMTctOS0xNi01LTE5LTN6IiBmaWxsPSIjNDYyMTA1Ii8+CjxwYXRoIHRyYW5zZm9ybT0idHJhbnNsYXRlKDg3NSwyMjgpIiBkPSJtMCAwaDM2bDE5IDMgMTYgNSAxNyA5IDEyIDExIDcgOSA1IDExIDMgMTN2MjRsLTIyIDE0My0xMyA5MS0xMCA4MC04IDc1LTYgNjktMiAzMXY0M2wzIDE1IDQgOSA2IDggMTAgOSA2IDcgNCAxMCAxIDEwLTMgMTMtNyAxMS01IDYtMTQgMTEtMTggMTAtMjAgOC0xOSA2LTIyIDUtMjAgMy0xMCAxaC0zN2wtMjAtMy0xNS00LTE4LTgtMTMtOS0xMy0xMi0xMC0xNC04LTE3LTQtMTMtMy0xOXYtMjFsNC0zNSAxMy05NCAxMS03OSAxLTMtMzQgNy0xMTEgMjItMzEgNmgtNGwtMyAyMi0xMiA3OC02IDQ3LTEgMTB2MjhsNCAxMyA0IDYgOCA5IDQgOCAyIDgtMSAxMy00IDEwLTkgMTEtMTQgMTEtMTcgOS0yNSA5LTI0IDYtMjUgNC0yNCAyaC0yMGwtMTktMi0yMS01LTE2LTctMTQtOS0xMC05LTEwLTEzLTgtMTctNS0xOS0xLTExdi0xM2wzLTI2IDE2LTEwMSAxOC0xMTcgMTctMTIwIDE2LTExOCAyLTE4di0yMWwtMy04LTYtNS05LTMtMTctMy0xNC03LTgtOS00LTExdi0xMWw0LTEyIDktMTIgNy03IDE1LTExIDI1LTEzIDI0LTkgMjgtOCAyNC01IDI2LTQgMjAtMmg0MmwyMSAzIDE4IDUgMTYgOCAxMSA4IDggOSA1IDggNSAxNSAxIDV2MjVsLTE5IDEyMy0xMCA3Mi0xIDUgMTk3LTQwIDE5LTExNCAzLTIwdi0xMmwtMS00LTQtMi04LTctNi05LTEtM3YtMTRsNC0xMCA2LTggOS05IDEwLTcgMTQtOCAxOS04IDI0LTcgMjQtNHptMCAzNS0yMSAzLTIzIDYtMTUgNi0xMyA3LTkgNy0xIDUgOCA2IDYgOSAyIDh2MTlsLTcgNDctMTYgOTYtMyAxMC02IDktOSA1LTIzIDUtMTE3IDI0LTgyIDE2LTEyIDEtNy0zLTUtNS0yLTR2LTE1bDE0LTk2IDEzLTgxIDUtMzN2LTE4bC0zLTEwLTktMTAtMTAtNi0xMy00LTE4LTNoLTQwbC0zMyA0LTMzIDctMjQgNy0yMCA4LTE5IDEwLTEzIDEwLTMgMyAxIDQgMjMgNSAxNCA3IDEwIDkgNyAxNCAyIDh2MjlsLTEwIDc4LTE4IDEyNy0yMiAxNDctMTggMTE2LTMgMjV2MjBsMyAxNSA4IDE2IDkgMTAgMTAgNyAxNCA2IDE0IDMgNyAxaDMzbDI0LTMgMjctNiAyMi04IDE3LTkgNy02IDEtNi0xMC0xMy02LTEzLTMtMTItMS03di0yNmw0LTM3IDEwLTcwIDEwLTY0IDMtOSA2LTcgOC00IDEwNC0yMSAxMDAtMjAgMTMtMiA3IDIgNSA0IDMgN3YxMWwtMTAgNzMtMTUgMTA1LTUgNDB2MzJsNCAxNiA5IDE3IDEzIDEzIDE0IDggMTEgNCAxNSAzIDExIDFoMTlsMjItMiAyNS01IDIwLTYgMTUtNiAxNy05IDEyLTExdi01bC0xMy0xMi03LTktNi0xMy00LTE1LTItMTh2LTM4bDQtNTcgOC04MyAxMi0xMDAgMTItODMgMTQtOTIgMTAtNjMgMi0xNXYtMTZsLTQtMTEtOS0xMC0xMi02LTE2LTQtOC0xeiIgZmlsbD0iI0Y4RjdGMyIvPgo8cGF0aCB0cmFuc2Zvcm09InRyYW5zbGF0ZSg5MTQsNTc4KSIgZD0ibTAgMGgxdjEybC05IDc0LTggODMtNCA1N3YzOGwyIDE4IDQgMTUgOCAxNiA5IDEwIDkgOHY1bC04IDgtMTMgOC0xNyA4LTIyIDctMjIgNS0xNSAyLTE0IDFoLTE5bC0xNy0yLTE1LTQtMTYtOC0xMC05LTgtOS04LTE3LTMtMTN2LTMybDUtNDAgMTYtMTEzIDYtNDMgMi01IDE1LTQgMjMtNiAzMy0xMSAyNC0xMCAxOS05IDE3LTEwIDE3LTEyIDE1LTE0eiIgZmlsbD0iI0ZEQkUzQyIvPgo8cGF0aCB0cmFuc2Zvcm09InRyYW5zbGF0ZSgzMzQsNjU5KSIgZD0ibTAgMGgybDEgNyA0IDExIDYgMTAgMyAzdjJsNCAyIDEwIDcgMTMgNSAxNCAzIDggMWg0MGwzMS00IDI1LTR2MTBsLTEyIDgwLTYgNDctMSAxMnYyNmwzIDE2IDUgMTIgNiAxMCA2IDctMSA2LTkgNy0xNyA5LTI0IDgtMjMgNS0yNCAzaC0zM2wtMTctMy0xNC01LTEwLTYtMTAtOS02LTktNS0xMS0zLTE1di0yMGw1LTM4IDIxLTEzNiA3LTQ3eiIgZmlsbD0iI0ZEQkUzQyIvPgo8cGF0aCB0cmFuc2Zvcm09InRyYW5zbGF0ZSgzNTYsNzk2KSIgZD0ibTAgMGgxMmw4IDQgNiA3IDIgN3Y3bC0zIDEwLTggOS03IDNoLTEzbC04LTQtNi03LTItNXYtMTJsNS0xMCA4LTd6IiBmaWxsPSIjRjhGOEY2Ii8+Cjwvc3ZnPgo=" alt="Regression CI"/></a>
<img src="https://img.shields.io/badge/language-Wren-6d2afa?logo=wren" alt="Wren"/>
<img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"/>
<img src="https://img.shields.io/badge/version-0.1.0-blue" alt="Version 0.1.0"/>
<a href="https://github.com/wrenlift/WrenLift"><img src="https://img.shields.io/badge/powered_by-WrenLift-2563eb" alt="Powered by WrenLift"/></a>
</p>

---

[Wren](https://wren.io) shines as an embedded scripting language:
small, fast to integrate, designed to slot into games, editors,
and tools written in C or C++. That's the use case Wren is
built for, and it's a good one.

**Hatch** offers a complementary path. When your project *is*
Wren (a CLI, a service, a library shared between Wren programs),
Hatch plus [WrenLift](https://github.com/wrenlift/WrenLift) is the
toolchain that lets you write it, package it, and run it on its
own. Same language, same idioms, different deployment story.

If you know Wren, you already know how to use this. What you need
is a place to put your code and a way to ship it.

## Install

The `hatch` binary ships alongside the WrenLift runtime: one install
gives you both `wlift` (the runtime) and `hatch` (this CLI) on your
`$PATH`.

```sh
curl -fsSL https://raw.githubusercontent.com/wrenlift/WrenLift/main/install.sh | bash
```

That fetches the latest GitHub Release, verifies the SHA256, and
drops both binaries into `~/.local/bin`. Override with
`INSTALL_DIR=/usr/local/bin` or pin a tag via `WLIFT_VERSION=v0.1.0`.

macOS (arm64, x86_64) and Linux (x86_64, aarch64) are supported.
Windows users can grab the binaries manually from
[Releases](https://github.com/wrenlift/WrenLift/releases).

Or from source:

```sh
git clone https://github.com/wrenlift/WrenLift
cd WrenLift
cargo build --release
# binaries land in target/release/{wlift,hatch}
```

`wlift --version` and `hatch --version` should both print `0.1.0`.

## Your first Wren project

Create an empty directory and let `hatch` scaffold it:

```sh
hatch init hello-wren
cd hello-wren
```

You'll find two files:

```
hello-wren/
├── hatchfile      # project manifest (TOML)
└── main.wren      # entry point
```

`main.wren` is a regular Wren program. Open it:

```wren
// Entry point for package 'hello-wren'. `hatch run` executes this file.
System.print("hello from hello-wren")
```

Run it:

```sh
$ hatch run
hello from hello-wren
```

That's your full local loop: write Wren, run Wren.

## Add more Wren to the project

Drop another `.wren` file next to `main.wren`:

```wren
// counter.wren
class Counter {
  construct new() { _n = 0 }
  tick() { _n = _n + 1 }
  count { _n }
}
```

Import it from `main.wren`:

```wren
// main.wren
import "counter" for Counter

var c = Counter.new()
for (i in 0..4) c.tick()
System.print("count: %(c.count)")
```

`hatch` discovers every `.wren` file in the workspace on its own.
If you want explicit control over module order, list them in the
`hatchfile`:

```toml
name    = "hello-wren"
version = "0.1.0"
entry   = "main"
modules = ["counter", "main"]
```

Run again:

```sh
$ hatch run
count: 5
```

## Package it

When you're ready to ship:

```sh
$ hatch build
built 1241 bytes from . → ./hello-wren.hatch
```

The resulting `hello-wren.hatch` is a single file that carries the
compiled bytecode for every module in the project. Hand it to
someone else and they can run it without the source tree:

```sh
$ hatch run ./hello-wren.hatch
count: 5
```

Curious what's inside?

```sh
$ hatch inspect hello-wren.hatch
hatch: hello-wren 0.1.0
  entry:   main
  modules: counter, main
  sections:
       Wlbc        861 bytes  counter
       Wlbc        412 bytes  main
```

## Depend on other hatches

A `.hatch` file is a reusable library. Once you have a library
hatch somewhere on disk, you can preload it before running your
app:

```sh
hatch run --with ../some-lib/some-lib.hatch
```

Declarative dependencies in the `hatchfile` (and a `hatch tidy`
resolver that fetches them from a registry) are next. The CLI
already shows the planned surface:

```sh
$ hatch add some-lib 0.2
hatch: not yet implemented: add some-lib@0.2 — resolver + registry
       lookups are planned; see the README roadmap
```

## `hatchfile`

Every Wren project has one. Today's fields:

```toml
name    = "hello-wren"
version = "0.1.0"
entry   = "main"                      # module to run

modules = ["counter", "main"]         # install order; auto-filled if empty

# [dependencies]                      # not yet wired
# std  = "0.3"
# http = { version = "0.1", features = ["tls"] }
```

## Commands today

- `hatch init [DIR]` — scaffold a `hatchfile` + `main.wren`.
- `hatch build [DIR]` — pack the workspace into a `.hatch`.
- `hatch run [TARGET] [--with PKG]` — build + run, or run a
  pre-built `.hatch`. `--with` preloads dependency hatches.
- `hatch inspect PACKAGE` — print manifest + section listing.

`add` / `remove` / `tidy` / `get` / `publish` are stubbed and
print a roadmap message; the resolver and registry client are
where they live.

## What lives in this repo

This is the ecosystem repo, not a Rust project. The `hatch` CLI
source lives in [WrenLift](https://github.com/wrenlift/WrenLift)
so one install gets you both binaries. What you'll find here:

- `packages/` — the official standard-library hatches (`std`,
  `http`, `json`, `test`, …) as they land.
- `index.toml` — a git-readable mirror of the live hatch catalog.
  Regenerated automatically from the Supabase-backed `packages`
  table every few hours via
  [`.github/workflows/sync-index.yml`](.github/workflows/sync-index.yml).
  Don't edit by hand; publish your package with `hatch publish`
  instead.
- The future home of the registry service, ecosystem docs, and
  any dev tools that outgrow the single-binary CLI.

## License

MIT.
