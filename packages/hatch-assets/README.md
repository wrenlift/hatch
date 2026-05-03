A content-addressable assets database with hot reload. One `Assets` API, two backends: filesystem-walking on native (SHA-256 indexed, watched via `Hatch.watchFile`), and manifest-driven on web (lazy `fetch` reads against an `assets-manifest.json` shipped alongside the bundle). Edits to a shader, texture, or config file fire registered subscribers on the next safepoint.

## Overview

Open a database at a directory root, then read assets by relative path. Bytes and text load lazily, then cache until the file's content hash advances. Two paths with identical contents resolve to the same hash, so caches keyed by `asset.hash` dedupe naturally.

```wren
import "@hatch:assets" for Assets

var db = Assets.open("assets")

var shader = db.text("shaders/triangle.wgsl")
var pixels = db.bytes("textures/atlas.png")
```

`db.get(path)` re-stats on each call: if the on-disk `mtime` advanced, the file is re-hashed; if the hash actually changed, the cached `Asset` invalidates and the next read pulls fresh bytes. Mtime-only touches stay silent.

## Hot reload

Register a hook with `db.on(path)` and the dev loop wires it through `Hatch.watchFile` for you. The hook fires on the next safepoint after the content hash advances.

```wren
db.on("shaders/triangle.wgsl") {|asset|
  System.print("shader changed (%(asset.hash[0..7])); rebuild pipeline")
}
```

`@hatch:gpu`'s shader pipeline and `@hatch:game`'s texture / mesh / audio loaders sit on top of this directly. You don't need to poll, debounce, or diff.

> **Note: Web target uses the manifest, not the filesystem**
> On `#!wasm` builds the package re-exports `assets_web.wren` instead. There is no filesystem walk and no hot reload. The page must ship an `assets-manifest.json` next to the assets, and reads go through `fetch`. The Wren-level surface stays identical; the production bundle just doesn't watch.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Native backend depends on `@hatch:fs` and `@hatch:hash`; web backend depends on `@hatch:json`. The runtime imports the whole package on either target; the inactive backend's foreign methods stay unbound and inert.
