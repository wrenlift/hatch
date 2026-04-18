<p align="center">
<img style="display: block;" src="logo.png" alt="hatch Logo" width="250"/>
</p>

<h1 align="center">hatch</h1>

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

A wrenlift **workspace** is any directory containing a `hatchfile` at its root. `hatch` commands operate on that workspace.

## Layout

```
cli/          # the `hatch` binary
packages/     # official hatches (std, http, ...)
```

## Today

- `hatch init [DIR]` — scaffold a `hatchfile` + `main.wren` stub.
- `hatch build [DIR]` — pack a workspace into a `.hatch`.
- `hatch run [TARGET] [--with PKG]` — build + run a workspace, or run a `.hatch` directly. `--with` preloads dependency hatches.
- `hatch inspect PACKAGE` — print manifest + section listing.

`hatch add` / `remove` / `tidy` / `get` / `publish` are stubbed so the CLI surface is visible; the resolver and registry client land in follow-up work.

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
