Process-level primitives: platform, environment variables, argv, TTY detection, exit codes. Provides one class, `Os`, on top of the runtime's `os` module. Callers do not need to know which features are native versus pure-Wren; the boundary shifts as the runtime grows but the surface stays stable.

## Overview

Most methods are direct passthroughs. The cases worth pointing out are `env(name, default_)` (which saves a `|| "default"` at every call site) and `argv` (which drops the program name so it lines up with what `@hatch:cli` expects).

```wren
import "@hatch:os" for Os

System.print(Os.platform)             // "macos" / "linux" / "windows"
System.print(Os.arch)                 // "aarch64" / "x86_64"

var port = Os.env("PORT", "8080")
Os.setEnv("LOG_LEVEL", "debug")

System.print(Os.argv)                 // user args, no program name
System.print(Os.isatty(Os.STDOUT))    // true if connected to a terminal
```

`Os.envMap` snapshots the entire environment as a `Map<String, String>`. The result is a copy; mutating it does not change the live process state. Round-trip via `Os.setEnv` for that.

## TTY detection

The `STDIN` / `STDOUT` / `STDERR` constants are the standard 0 / 1 / 2 file descriptors. Pair with `@hatch:fmt` to gate ANSI colour on `Os.isatty(Os.STDOUT)`:

```wren
import "@hatch:fmt" for Fmt
import "@hatch:os"  for Os

Fmt.enabled = Os.isatty(Os.STDOUT)
```

> **Note: `exit` does not run cleanup**
> `Os.exit(code)` calls the host's process-exit syscall directly. Pending fibers do not drain, finalisers do not fire, and any non-flushed `System.print` output may be lost on some platforms. Reserve it for the top of `main` after a fatal-error branch.

## Compatibility

Wren 0.4 and WrenLift runtime 0.1 or newer. Native only; `#!wasm` builds get most of these via `@hatch:web`'s `Browser` namespace instead. `Os.username` is best-effort via `$USER` / `$USERNAME` and may be `null` in heavily-restricted environments.
