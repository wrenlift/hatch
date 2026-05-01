Clocks, sleep, and UTC timestamp formatting. Two classes — `Clock` for the wall-clock and monotonic time sources, and `Time` for formatted UTC moments. Pair with `@hatch:datetime` when you need offsets and calendar arithmetic; this package is the thin layer over the runtime's `time` module.

## Overview

`Clock.unix` is wall-clock seconds since the Unix epoch — fine for timestamps but vulnerable to clock adjustment. `Clock.mono` is a monotonic source that always advances at one second per second — use it for measuring durations.

```wren
import "@hatch:time" for Time, Clock

System.print(Clock.unix)            // 1776700800.123
System.print(Clock.mono)            // monotonic, for elapsed work
Clock.sleep(0.5)                    // 500ms
Clock.sleepMs(250)

var elapsed = Clock.elapsed {
  doWork()
}
System.print("took %(elapsed)s")
```

`Time.now` captures the current moment as a `Time` value; `Time.fromUnix(seconds)` wraps an existing timestamp. Component getters expose `year` / `month` / `day` / `hour` / `minute` / `second` / `millisecond` / `weekday` (`0` = Monday). The ISO 8601 / RFC 3339 string is one getter away:

```wren
var t = Time.now
System.print(t.iso)                          // "2026-04-20T14:23:45Z"
System.print(t.format("YYYY-MM-DD HH:mm:ss")) // "2026-04-20 14:23:45"
```

`format` recognises `YYYY`, `MM`, `DD`, `HH`, `mm`, `ss`, `SSS`; everything else passes through verbatim. Full strftime is a later upgrade.

> **Note — UTC only**
> `Time` doesn't model offsets or named zones. For local time, DST handling, or arithmetic over `Duration`, reach for `@hatch:datetime`, which layers a real value-type on top of this primitive.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Built on the runtime's `time` module — works on every supported target. `Clock.sleep` is a real OS sleep on native; on `#!wasm` it goes through the runtime's microtask scheduler.
