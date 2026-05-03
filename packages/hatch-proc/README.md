Subprocess spawn and capture with a fiber-friendly lifecycle, streaming IO, and pipeline composition. `Proc.exec` is the one-shot blocking call; `Proc.run` returns a `Process` handle you query, write to, kill, or chain into another. `Pipeline.of(...)` strings several commands together and waits on the tail.

## Overview

For a quick "run this and tell me what it printed," `Proc.exec` blocks and returns a `Result`. For anything streaming, long-running, or chained, `Proc.run` hands back a handle.

```wren
import "@hatch:proc" for Proc, Pipeline

var r = Proc.exec(["echo", "hi"])
System.print(r.ok)         // true
System.print(r.stdout)     // "hi\n"

var p = Proc.run(["long-running", "--flag"], {
  "cwd": "/tmp",
  "env": { "FOO": "bar" }
})

p.writeStdin("line 1\n")
p.writeStdin("line 2\n")
p.closeStdin

while (p.alive) Fiber.yield()
System.print(p.wait.code)
```

`Result` exposes `code`, `stdout`, `stderr`, `timedOut`, and an `ok` shorthand (`code == 0 && !timedOut`). `Process` has `pid`, `alive`, `tryWait` (non-blocking), `wait` (blocks), `kill`, `forget`.

## Pipelines

`Pipeline.of(commands)` wires each hop's stdout into the next hop's stdin. The last `Result` is what `wait` returns.

```wren
var r = Pipeline.of([
  ["cat", "/etc/hosts"],
  ["grep", "localhost"],
  ["wc", "-l"]
]).wait

System.print(r.stdout)
```

Manual chaining via `{"stdinFrom": prev}` works the same way:

```wren
var p1 = Proc.run(["cat", "/etc/hosts"])
var p2 = Proc.run(["wc", "-l"], { "stdinFrom": p1 })
System.print(p2.wait.stdout)
```

## Fiber-cooperative shape

The `tryWait` poll plus `Fiber.yield()` pattern is the canonical "wait without blocking the runtime" idiom. Drop it inside a fiber and put the fiber on `@hatch:events`'s `Scheduler` to run several subprocesses concurrently.

```wren
import "@hatch:events" for Scheduler

var jobs = [
  Fiber.new { Proc.exec(["build", "a"]) },
  Fiber.new { Proc.exec(["build", "b"]) },
  Fiber.new { Proc.exec(["build", "c"]) }
]
var results = Scheduler.runAll(jobs)
```

> **Warning: kill is best-effort**
> `p.kill` sends SIGKILL on Unix and `TerminateProcess` on Windows. Children of the killed process are not reaped automatically. A subprocess that spawns its own subprocesses needs process-group plumbing on the spawn side, or it will leave orphans.

## Compatibility

Wren 0.4 with WrenLift runtime 0.1 or newer. Native only; there is no browser equivalent. Depends on `@hatch:io` for the `Reader` / `Writer` shapes used by `writeStdin` / `readStdout`.
