Filesystem I/O — read, write, stat, list, walk. One class — `Fs` — backed by the runtime's `std::fs` bindings. Operations are synchronous and abort on failure; wrap in `Fiber.new { ... }.try()` when you need to recover from a missing file or a permission error.

## Overview

The text / lines / bytes split mirrors what most callers actually want. Lines drops the trailing empty element when a file ends in a newline, so a file containing `"a\nb\n"` yields `["a", "b"]` rather than `["a", "b", ""]`.

```wren
import "@hatch:fs" for Fs

var config = Fs.readText("config.json")
Fs.writeText("config.json", config)

var lines = Fs.readLines("notes.txt")
Fs.writeLines("notes.txt", lines + ["another"])

var bytes = Fs.readBytes("payload.bin")
Fs.writeBytes("payload.bin", bytes)

System.print(Fs.exists("config.json"))  // true
System.print(Fs.size("payload.bin"))     // bytes

Fs.mkdirs("var/cache")
Fs.removeTree("var/cache")
```

`Fs.walk(root)` returns every nested path relative to `root`, sorted per-level. It doesn't filter anything — callers exclude `.git/`, `node_modules/`, and friends after the fact.

## Sandboxing and capabilities

Reads and writes go through whatever filesystem capability the workspace grants. `hatchfile` declarations like `fs = ["./assets", "./var"]` constrain the package to those subtrees; `--fs` on `hatch run` opens the dev loop unrestricted.

> **Warning — `removeTree` does what it says**
> No prompt, no recovery. Be deliberate about the path you pass — especially when the path comes from user input. Validate it against your workspace root first.

`Fs.cwd`, `Fs.home`, `Fs.tmpDir` give you the standard locations the host process inherits. They're plain strings — combine via `@hatch:path` rather than concatenating manually so Windows builds keep working.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Native only — `#!wasm` builds reach for `@hatch:assets` (manifest-driven) instead. Pair with `@hatch:path` for portable path joining.
