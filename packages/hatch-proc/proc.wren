// `@hatch:proc` — subprocess spawn & capture with fiber-friendly
// lifecycle, IPC, and chaining.
//
// ```wren
// import "@hatch:proc" for Proc, Process, Pipeline
// ```
//
// One-liner (blocking run + wait):
//
// ```wren
// var r = Proc.exec(["echo", "hi"])
// r.code / r.stdout / r.stderr / r.ok / r.timedOut
// ```
//
// Handle-based (fiber-friendly, streaming stdin, kill, chain):
//
// ```wren
// var p = Proc.run(["long-running", "--flag"], {
//   "cwd": "/tmp",
//   "env": {"FOO": "bar"}
// })
//
// // 1. Lifecycle
// p.alive                // Bool
// p.pid                  // Num
// p.tryWait              // Result or null (non-blocking)
// p.wait                 // Result (blocks until exit)
// p.kill                 // terminate the child
// p.forget               // drop the registry entry
//
// // 2. IPC
// p.writeStdin("line 1\n")
// p.writeStdin("line 2\n")
// p.closeStdin           // sends EOF
//
// // 3. Chaining (each hop takes the previous one's stdout)
// var pipeline = Pipeline.of([
//   ["cat", "/etc/hosts"],
//   ["grep", "localhost"],
//   ["wc", "-l"]
// ])
// var r = pipeline.wait
// System.print(r.stdout)
//
// // Or manually:
// var p1 = Proc.run(["cat", "/etc/hosts"])
// var p2 = Proc.run(["wc", "-l"], {"stdinFrom": p1})
// System.print(p2.wait.stdout)
// ```
//
// Fiber pattern:
//
// ```wren
// var fib = Fiber.new {
//   var p = Proc.run(["slow-thing"])
//   while (p.alive) Fiber.yield()
//   return p.tryWait
// }
// ```

import "proc"     for ProcCore
import "@hatch:io" for Reader, Writer

class Result {
  construct new_(code, stdout, stderr, timedOut) {
    _code     = code
    _stdout   = stdout
    _stderr   = stderr
    _timedOut = timedOut
  }

  code     { _code }
  stdout   { _stdout }
  stderr   { _stderr }
  timedOut { _timedOut }
  ok       { _code == 0 && !_timedOut }

  toString {
    if (_timedOut) return "Result(timed out)"
    return "Result(exit %(_code))"
  }

  // Unwrap a raw result map from the core layer.
  static from_(raw) {
    if (raw == null) return null
    return Result.new_(raw["code"], raw["stdout"], raw["stderr"], raw["timedOut"])
  }
}

class Process {
  // Direct construction is intended for internal use; callers
  // should go through `Proc.run` / `Proc.spawn`.
  construct from_(id) {
    _id = id
  }

  id { _id }
  pid { ProcCore.pid(_id) }

  // --- Lifecycle -------------------------------------------------------

  alive { ProcCore.alive(_id) }

  /// Non-blocking: Result if the child exited, null if still
  /// running. Idempotent after the first non-null return —
  /// repeat calls re-emit the same Result.
  tryWait { Result.from_(ProcCore.tryWait(_id)) }

  /// Block until the child exits, return the Result. Waits even
  /// if called multiple times (the second call hits the cached
  /// result inside the runtime).
  wait { Result.from_(ProcCore.wait(_id)) }

  /// Send SIGKILL (POSIX) / TerminateProcess (Windows). Doesn't
  /// wait for the process to actually exit — follow with `wait`
  /// to reap.
  kill { ProcCore.kill(_id) }

  /// Drop the registry entry. Call after consuming the result if
  /// you're spawning lots of short-lived processes in a long-
  /// running host — otherwise entries accumulate until VM exit.
  forget { ProcCore.forget(_id) }

  // --- IPC -------------------------------------------------------------

  writeStdin(data) {
    if (!(data is String)) Fiber.abort("Process.writeStdin: data must be a string")
    ProcCore.writeStdin(_id, data)
  }

  closeStdin { ProcCore.closeStdin(_id) }

  // --- Streaming (via @hatch:io) ---------------------------------------

  /// A `Reader` that pulls stdout bytes as they arrive. Use for
  /// long-running processes whose output you want to consume
  /// incrementally (line by line, chunk by chunk).
  ///
  /// ```wren
  /// var p = Proc.run(["tail", "-f", "/var/log/app.log"])
  /// var r = p.stdoutReader
  /// var line = r.readLine
  /// while (line != null) {
  ///   System.print(line)
  ///   line = r.readLine
  /// }
  /// ```
  ///
  /// Calling `wait` on the process while a reader is active is
  /// safe — the remaining bytes will be drained and the final
  /// `Result.stdout` reflects everything that passed through.
  stdoutReader {
    var pid = _id
    return Reader.withFn {|max| ProcCore.readStdoutBytes(pid, max) }
  }

  stderrReader {
    var pid = _id
    return Reader.withFn {|max| ProcCore.readStderrBytes(pid, max) }
  }

  /// Fiber-cooperative stdout reader. Use inside
  /// `Fiber.new { ... }` to drain output without blocking sibling
  /// fibers:
  ///
  /// ```wren
  /// var fib = Fiber.new {
  ///   var r = p.stdoutAsync
  ///   var line = r.readLine
  ///   while (line != null) {
  ///     // ...
  ///     line = r.readLine
  ///   }
  /// }
  /// ```
  stdoutAsync {
    var pid = _id
    return Reader.withTryFn {|max| ProcCore.tryReadStdoutBytes(pid, max) }
  }

  stderrAsync {
    var pid = _id
    return Reader.withTryFn {|max| ProcCore.tryReadStderrBytes(pid, max) }
  }

  /// A `Writer` that feeds stdin. Accepts `Buffer` / `String` /
  /// `List<Num>`. `close` (or `flush` if that's all you want)
  /// sends EOF via `closeStdin`.
  ///
  /// ```wren
  /// var p = Proc.run(["cat"])
  /// var w = p.stdinWriter
  /// w.write("hello\n")
  /// w.write(Buffer.fromBytes([0xC3, 0xA9]))
  /// w.close
  /// System.print(p.wait.stdout)
  /// ```
  stdinWriter {
    var pid = _id
    var w = Writer.withFn {|bytes| ProcCore.writeStdinBytes(pid, bytes) }
    w.setCloseFn_ { ProcCore.closeStdin(pid) }
    return w
  }

  toString { "Process(id=%(_id))" }
}

class Proc {
  /// Spawn a process and return a handle. Doesn't block — the
  /// child runs in the background until you `wait` on it.
  static run(argv)          { run(argv, {}) }
  static run(argv, options) {
    if (!(argv is List)) Fiber.abort("Proc.run: argv must be a list")
    if (options != null && !(options is Map)) {
      Fiber.abort("Proc.run: options must be a Map")
    }
    if (options == null) options = {}

    var cwd   = options.containsKey("cwd")   ? options["cwd"]   : null
    var env   = options.containsKey("env")   ? options["env"]   : null
    var stdin = options.containsKey("stdin") ? options["stdin"] : null

    // stdinFrom: another Process whose stdout becomes our stdin.
    var stdinFromId = null
    if (options.containsKey("stdinFrom")) {
      var donor = options["stdinFrom"]
      if (!(donor is Process)) {
        Fiber.abort("Proc.run: stdinFrom must be a Process")
      }
      stdinFromId = donor.id
    }

    var id = ProcCore.spawn(argv, cwd, env, stdin, stdinFromId)
    return Process.from_(id)
  }

  /// Blocking shortcut: spawn + wait, returns Result directly.
  /// Useful when you don't care about the handle.
  static exec(argv)          { exec(argv, {}) }
  static exec(argv, options) {
    if (!(argv is List)) Fiber.abort("Proc.exec: argv must be a list")
    if (options != null && !(options is Map)) {
      Fiber.abort("Proc.exec: options must be a Map")
    }
    if (options == null) options = {}

    var cwd     = options.containsKey("cwd")     ? options["cwd"]     : null
    var env     = options.containsKey("env")     ? options["env"]     : null
    var stdin   = options.containsKey("stdin")   ? options["stdin"]   : null
    var timeout = options.containsKey("timeout") ? options["timeout"] : null

    var raw = ProcCore.run(argv, cwd, env, stdin, timeout)
    return Result.from_(raw)
  }

  /// Shell pipeline. Explicit opt-in so callers don't pick up
  /// shell parsing by accident. Equivalent to `sh -c "…"`.
  static shell(cmd)          { shell(cmd, {}) }
  static shell(cmd, options) {
    if (!(cmd is String)) Fiber.abort("Proc.shell: cmd must be a string")
    return exec(["sh", "-c", cmd], options)
  }

  /// "Run this and abort if it failed" — ergonomic for mechanical
  /// shell-outs where non-zero is a real bug.
  static check(argv)          { check(argv, {}) }
  static check(argv, options) {
    var r = exec(argv, options)
    if (!r.ok) {
      var label = argv.count > 0 ? argv[0] : "?"
      if (r.timedOut) Fiber.abort("Proc.check: %(label) timed out")
      Fiber.abort("Proc.check: %(label) exited %(r.code): %(r.stderr)")
    }
    return r
  }
}

/// Multi-stage pipeline. Each stage's stdout feeds the next
/// stage's stdin. The final stage captures; intermediate stages
/// stream through without buffering in Wren.
class Pipeline {
  construct new_(processes) {
    _processes = processes
  }

  /// Build and start a pipeline from a list of argv lists.
  /// Returns a Pipeline that has already spawned every stage —
  /// call `wait` to collect the final result.
  static of(stages) {
    if (!(stages is List) || stages.count == 0) {
      Fiber.abort("Pipeline.of: expected a non-empty list of argv lists")
    }
    var procs = []
    var prev = null
    var i = 0
    while (i < stages.count) {
      var stage = stages[i]
      i = i + 1
      var opts = {}
      if (prev != null) opts["stdinFrom"] = prev
      var p = Proc.run(stage, opts)
      procs.add(p)
      prev = p
    }
    return Pipeline.new_(procs)
  }

  processes { _processes }

  /// Wait on the final stage, returning its Result. Earlier
  /// stages are expected to finish on their own once the last
  /// one drains their stdout — we reap them too so their
  /// registry entries don't leak.
  wait {
    var last = _processes[_processes.count - 1]
    var result = last.wait
    // Reap intermediate stages. They finish once the next stage
    // closes its stdin (i.e. when we wait on it), but we still
    // need to collect their exit codes.
    var i = 0
    while (i < _processes.count - 1) {
      _processes[i].wait
      i = i + 1
    }
    return result
  }

  /// Kill every stage in the pipeline.
  kill {
    var i = 0
    while (i < _processes.count) {
      _processes[i].kill
      i = i + 1
    }
  }

  toString { "Pipeline(%(_processes.count) stages)" }
}
