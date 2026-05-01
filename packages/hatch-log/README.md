A level-filtered structured logger with ANSI colours. One class — `Log` — with `debug` / `info` / `warn` / `error` methods, a global level threshold, and pluggable writer / prefix / colour controls. Output is a single line per call, with the level tag rendered through `@hatch:fmt`.

## Overview

Default level is `INFO`, default writer is `System.print`. Set the level once at startup, log freely from anywhere, override the writer when you need to pipe lines into a file or a structured-log collector instead.

```wren
import "@hatch:log" for Log

Log.info("server starting on port %(port)")
Log.warn("config missing, using defaults")
Log.error("connection lost")
Log.debug("cache hit key=%(k)")
```

Level ordering (lowest to highest): `Log.DEBUG`, `Log.INFO`, `Log.WARN`, `Log.ERROR`. Calls below the current threshold are dropped before any string interpolation work, so `Log.debug("expensive %(formatPayload(p))")` is cheap when debug is off — the message argument still evaluates, but Wren string interpolation is fast and the level check happens first.

## Configuring output

```wren
Log.level  = Log.DEBUG
Log.color  = false                              // CI / file output
Log.prefix = "[api] "                            // tag every line
Log.writer = Fn.new {|line| Fs.appendText("app.log", line + "\n") }
```

Tags are fixed-width (`DEBUG`, `INFO `, `WARN `, `ERROR`) so messages line up in a terminal. Setting `color = false` produces clean text suitable for log files; the ANSI codes are dropped at format time, not stripped after the fact.

> **Tip — one prefix per subsystem**
> The `prefix` is global. If you want per-subsystem tags, set `Log.prefix = "[api] "` near the top of each subsystem's entry function, or wrap `Log` in a thin per-subsystem class that prepends its own tag before delegating.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Depends on `@hatch:fmt` for ANSI colours. Pure-Wren elsewhere — works on every supported target.
