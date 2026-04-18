<p align="center">
<img style="display: block;" src="logo.png" alt="hatch Logo" width="250"/>
</p>

<h1 align="center">Hatch</h1>

<p align="center">
Build, run, and ship <a href="https://wren.io">Wren</a> programs as standalone projects. Powered by the <a href="https://github.com/wrenlift/WrenLift">WrenLift</a> runtime.
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

[Wren](https://wren.io) shines as an embedded scripting language —
small, fast to integrate, designed to slot into games, editors,
and tools written in C or C++. That's the use case Wren is
built for, and it's a good one.

**Hatch** offers a complementary path. When your project *is*
Wren — a CLI, a service, a library shared between Wren programs —
Hatch plus [WrenLift](https://github.com/wrenlift/WrenLift) is the
toolchain that lets you write it, package it, and run it on its
own. Same language, same idioms, different deployment story.

If you know Wren, you already know how to use this. What you need
is a place to put your code and a way to ship it.

## Install

The `hatch` binary ships alongside the WrenLift runtime — installing
WrenLift gives you both `wlift` (the runtime) and `hatch` (this CLI)
on your `$PATH` in one step:

```sh
# From source:
git clone https://github.com/wrenlift/WrenLift
cd WrenLift
cargo install --path .

# Or, once we publish:
cargo install wren_lift
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

That's your full local loop — write Wren, run Wren.

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
print a roadmap message — the resolver and registry client are
where they live.

## What lives in this repo

This is the ecosystem repo — not a Rust project. The `hatch` CLI
source lives in [WrenLift](https://github.com/wrenlift/WrenLift)
so one install gets you both binaries. What you'll find here:

- `packages/` — the official standard-library hatches (`std`,
  `http`, `json`, `test`, …) as they land.
- The future home of the registry service, ecosystem docs, and
  any dev tools that outgrow the single-binary CLI.

## License

MIT.
