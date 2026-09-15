# Concurrency

WrenLift has three ways to run more than one thing at once. A `Fiber` is a coroutine. A `Thread` is a task that runs on another OS thread and shares the heap. An `Isolate` is a separate VM with its own heap. This page explains what each one does, when control moves, what memory it can see, and how they work together. None of this needs a package: `Fiber` is a core class, and `thread` and `isolate` are built-in modules.

| | `Fiber` | `Thread` (module `thread`) | `Isolate` (module `isolate`) |
|---|---|---|---|
| Runs | one at a time, on the caller's thread | in parallel, on a pool of OS threads | in parallel, each on its own OS thread |
| Control moves | only when you say: `call`, `yield`, `transfer`, `sleep`, a wait | at any time | never between them |
| Memory | shared, and races cannot happen | shared: the same objects, the same heap | separate heaps: values are copied across |
| Waiting | `Fiber.sleep`, `Fiber.park` | `Mutex`, `Lock`, `Deque` | `Channel`, `join` |
| A data race is | impossible | possible; you guard against it | impossible |
| Underneath | a coroutine with a stack of its own | a fiber on a worker's scheduler | a VM per thread |

One rule connects them: **a `Thread` is a `Fiber` that runs on another OS thread.** Every task in the pool is a real `Fiber`. `Thread.current` returns it, and `Thread.yield()` is its `yield`. The difference is that a `Thread` runs at the same time as the code that made it. A plain `Fiber` never does. That is why it gets its own name.

## Fibers: coroutines

A `Fiber` is a function with its own stack. You run it by hand. Control moves only where the code says so, which means two fibers can never touch the same object at the same moment.

```wren
var reader = Fiber.new {
  for (line in ["one", "two", "three"]) Fiber.yield(line)
  return "done"
}
while (!reader.isDone) {
  var line = reader.call()
  if (line != "done") System.print(line)
}
```

`call` runs the fiber until it yields or returns, and hands the value back. `try` does the same but catches an abort into `fiber.error`. `transfer` hands control over without expecting it back. Compiled code can yield from any depth. A fiber's body is compiled like any other function.

### The scheduler

When you have many fibers waiting on timers or on each other, let the built-in scheduler run them:

```wren
var log = []
Fiber.spawn {
  log.add("a1")
  Fiber.sleep(30)          // a timer park; the others run meanwhile
  log.add("a2")
}
Fiber.spawn {
  log.add("b1")
  Fiber.yield()            // let the other tasks have a turn
  log.add("b2")
}
while (Fiber.tick(0)) Fiber.idle(100)
System.print(log)         // [a1, b1, b2, a2]
```

`Fiber.spawn(fn)` hands a fiber to the scheduler. `Fiber.tick(ms)` gives every ready task a turn and returns `true` while tasks remain. `Fiber.idle(ms)` blocks until a task is ready, a timer is due, or a wake arrives. Inside a task, `Fiber.sleep(ms)` parks on a timer. `Fiber.park(token, ms)` parks until someone calls `Fiber.wake(token)`, and that call can come from any thread. This is how the other two models hand a result back to a waiting fiber. At module top level, `Fiber.sleep` runs the scheduler itself until the time is up, so a program that never calls `tick` still sees its tasks run while it sleeps.

This is the shape a server wants: one task per connection, `idle` between polls, and no thread per request.

## Threads: parallel fibers on one heap

```wren
import "thread" for Thread, Mutex, Lock, Deque
```

`Thread.create(fn)` runs `fn` as a task on a worker thread. The workers start on the first call, one per hardware thread. Each new task goes to the worker with the least work. The task shares the heap with the caller. The lists, maps and objects it reaches are the caller's own, not copies. This is the model for CPU-bound work that wants every core:

```wren
import "thread" for Thread, Lock, Deque

class Fib {
  static of(n) {
    if (n < 2) return n
    return of(n - 1) + of(n - 2)
  }
}

var results = Deque.new()
var done = Lock.new()
for (i in 0...8) {
  Thread.create {
    results.add(Fib.of(30))
    done.release()
  }
}
for (i in 0...8) done.wait()   // eight units, one per task
var total = 0
while (results.count > 0) total = total + results.pop(false)
System.print(total)
```

Three things wait for a task:

- `Mutex` — `acquire()`, `tryAcquire()`, `release()`. Not reentrant. When it is released, the task that waited longest takes it.
- `Lock` — a counting lock. `release()` adds one unit. `wait()` takes one, or waits until there is one. `wait(ms)` gives up after `ms` and returns false. It starts at zero, so it works as a done signal or a semaphore.
- `Deque` — a queue any task can share. `add(v)` puts at the back, `push(v)` at the front. `pop(true)` waits for an item. `pop(false)` returns null when empty. `count` is the size.

A wait parks the *task*, not the OS thread. The worker keeps running its other tasks. When any thread calls `release`, the scheduler wakes the waiter. So a producer and consumer need no polling:

```wren
import "thread" for Thread, Mutex, Lock, Deque

var jobs = Deque.new()
var results = Deque.new()
var finished = Lock.new()

for (w in 0...4) {
  Thread.create {
    while (true) {
      var job = jobs.pop(true)        // parks until there is one
      if (job == null) break          // the stop marker
      results.add([job, job * job])
    }
    finished.release()
  }
}
for (n in 1..100) jobs.add(n)
for (w in 0...4) jobs.add(null)      // one stop marker per worker
for (w in 0...4) finished.wait()
System.print(results.count)           // 100
```

### The rules

Threads share memory, so the rules are the ones Go programmers know:

- **Two tasks writing the same list or map at the same time is a race.** The runtime does not catch it. Put a `Mutex` around shared structures, or give each task its own and merge at the end. A `Deque` is safe to share, which is what the examples do.
- **A fiber runs on the thread that made it.** Calling a fiber that another task created is an error. Make fibers inside the task that will drive them.
- **When a task aborts, it ends quietly.** Nothing is printed. Catch what you care about inside the task and report it through a `Deque`.
- **At module top level, a wait runs your own scheduler.** `done.wait()` in the examples runs any `Fiber.spawn` tasks on the main thread while it waits. `Fiber.sleep` works the same way there.
- Module variables, static fields and object fields are single-word writes. They never tear. Between threads, you see the writes in whatever order they landed.

The garbage collector stops every thread before it runs, wherever they are: in the interpreter, in compiled code, or in a tight loop that never allocates. Threads change nothing about how you write code that allocates a lot.

## Isolates: parallel and separate

```wren
import "isolate" for Isolate, Channel
```

An `Isolate` is a whole VM on its own thread, with its own heap. Nothing is shared. `Isolate.spawn(module, arg)` runs a module's top level on that thread with a *copy* of `arg`. Values come back as copies through a `Channel`. Use it when you want parallel work with no chance of a race, or work that must not be able to touch the main program at all: a plugin, a sandbox, or a request whose crash should stay its own.

```wren
// worker.wren
import "isolate" for Isolate
var arg = Isolate.arg                  // the copy of what spawn was given
var sum = 0
for (i in 0...arg["n"]) sum = sum + i
arg["reply"].send({"who": arg["who"], "sum": sum})
```

```wren
// main.wren
import "isolate" for Isolate, Channel
var reply = Channel.new()
var workers = []
for (k in 0...Isolate.cpus) {
  workers.add(Isolate.spawn("worker", {"who": k, "n": 1000000, "reply": reply}))
}
for (k in 0...Isolate.cpus) {
  var r = reply.receive()              // parks until a message lands
  System.print("%(r["who"]) -> %(r["sum"])")
}
for (w in workers) w.join()
```

These values can cross: `null`, booleans, numbers, strings, lists and maps of those, and `Channel` and `Isolate` handles. Anything else is an error at the send: an instance, a fiber, a function. A `Channel.receive` inside a `Fiber.spawn` task parks that task, so the main thread can collect from isolates while its other tasks run. `Isolate.spawn(module)` finds the module the same way `import` does. Under `hatch run` the program's own modules are available to it. Under `wlift` its loader and spec dependencies carry over.

## Which one

- Waiting on I/O or timers, many small things in flight, a server: use **fibers** and the scheduler. No parallelism, no locks, no races.
- CPU-bound work over shared data, on every core: use **threads**. Parallel, one heap, and you guard what is shared.
- Parallel work that must not share, or must not be able to break the main program: use **isolates**. Copies in, copies out.

They work together, and the seams are where you would expect:

- A task can make fibers and `call` them. It can also `Fiber.spawn` fibers onto its worker's scheduler. The worker runs those next to its tasks. The task waits for them with a `Lock`, not with `Fiber.tick`, because a task cannot drive the scheduler it is running on.
- A fiber on the main thread can wait on a `Lock` that a thread releases, or on a `Channel` that an isolate sends to. The main thread runs its other fibers in the meantime.
- An isolate is a whole program. Its module can start threads of its own, and those threads can drive fibers.
- A task can `receive` from an isolate's channel or `join` an isolate. It parks like anything else.

```wren
import "thread" for Thread, Lock, Deque
import "isolate" for Isolate, Channel

var done = Lock.new()

// A task that spawns fibers on its worker and waits for them.
Thread.create {
  var got = Lock.new()
  var acc = []
  for (i in 0...3) {
    Fiber.spawn {
      Fiber.sleep(5 * i)
      acc.add(i)
      got.release()
    }
  }
  for (i in 0...3) got.wait()
  System.print("task fibers %(acc)")
  done.release()
}

// A main-thread fiber woken by a thread.
var handoff = Lock.new()
Fiber.spawn {
  handoff.wait()
  System.print("main fiber woke")
  done.release()
}
Thread.create {
  Fiber.sleep(10)
  handoff.release()
}

// An isolate (the worker module from above), answered from a task.
var reply = Channel.new()
var iso = Isolate.spawn("worker", {"who": 0, "n": 100, "reply": reply})
Thread.create {
  System.print("isolate said %(reply.receive()["sum"])")
  done.release()
}

for (i in 0...3) done.wait()
iso.join()
```

## In the browser

A wasm module runs on one agent, so the three models change shape but keep their meaning. A `Fiber` suspends the same way it does anywhere else. The scheduler and the `thread` module run on that one agent: tasks take turns, a wait parks the task, and a release wakes it. A producer and consumer work as they do natively. Nothing runs at the same time, and `Thread.count` is 1. An `Isolate` is a Worker with memory of its own, and values still cross as copies. That is the part that runs in parallel in the browser.

The browser build has fibers today. The scheduler, threads and isolates follow in that order.
