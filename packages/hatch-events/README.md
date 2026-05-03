In-process pub/sub plus a cooperative fiber scheduler. `Signal` is a single-channel observer with disconnect closures; `EventEmitter` is the Node-style named-events shape; `Scheduler` drives a list of fibers until each one finishes. Pure Wren. `emit` runs synchronously on the caller, fibers cooperate at `Fiber.yield` boundaries.

## Overview

Pick the surface that matches the shape of the data. `Signal` for one channel many listeners; `EventEmitter` when there are several event names on one bus; `Scheduler` when you want to fan out work across fibers and join at a drain point.

```wren
import "@hatch:events" for Signal, EventEmitter, Scheduler

var onExit = Signal.new
var disconnect = onExit.connect {|code| System.print("exit: %(code)") }
onExit.emit(0)
disconnect.call()

var bus = EventEmitter.new
bus.on("data") {|chunk| handle(chunk) }
bus.once("end") { System.print("done") }
bus.emit("data", chunk)
bus.emit("end")
```

`Signal.connect` returns a disconnect closure so listeners can clean themselves up without the caller holding a `Fn` reference. `EventEmitter` mirrors Node: `on`, `once`, `off(event, fn)`, `offAll(event)`, `offAll`. Both classes iterate over a snapshot during `emit`, so a listener that disconnects itself or adds a new listener mid-emit is safe.

## Cooperative scheduling

`Scheduler.runAll(fibers)` drives every fiber in the list to completion, polling `fiber.try()` round-robin. Fibers that yield cooperate; CPU-bound fibers run to completion before the scheduler picks the next.

```wren
var jobs = [
  Fiber.new { fetchA() },
  Fiber.new { fetchB() },
  Fiber.new { fetchC() }
]

var results = Scheduler.runAll(jobs)
// results[i] is the return value, or the error string if that fiber aborted
```

`Scheduler.spawn(fn)` is a thin `Fiber.new` wrapper that documents intent: start work now, drain it later in a `runAll` batch.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Pure-Wren, with no native dependencies and no host capabilities. Pairs with `@hatch:http` and `@hatch:web` for IO-driven event flows.
