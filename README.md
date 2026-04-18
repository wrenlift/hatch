# hatch

The ecosystem for the [Wren](https://wren.io) scripting language,
powered by the [WrenLift](https://github.com/wrenlift/WrenLift)
runtime.

A wrenlift **workspace** is any directory containing a `hatchfile` at
its root. `hatch` commands operate on that workspace.

## Layout

```
cli/          # the `hatch` binary
packages/     # official hatches (std, http, ...)
```

## Today

- `hatch init [DIR]` — scaffold a `hatchfile` + `main.wren` stub.
- `hatch build [DIR]` — pack a workspace into a `.hatch`.
- `hatch run [TARGET] [--with PKG]` — build + run a workspace, or
  run a `.hatch` directly. `--with` preloads dependency hatches.
- `hatch inspect PACKAGE` — print manifest + section listing.

`hatch add` / `remove` / `tidy` / `get` / `publish` are stubbed so
the CLI surface is visible; the resolver and registry client land in
follow-up work.

## Dev setup

`cli` uses a path dependency on a sibling WrenLift checkout:

```toml
wren_lift = { path = "../../", default-features = false, features = ["cranelift"] }
```

Swap for a version constraint once WrenLift publishes.

## License

MIT.
