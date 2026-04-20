// @hatch:proc — subprocess spawn & capture.
//
//   import "@hatch:proc" for Proc
//
//   // One-shot. argv is a list: [program, ...args]. No shell
//   // parsing; arguments are passed verbatim.
//   var r = Proc.run(["ls", "-la"])
//   r.code      // 0
//   r.stdout    // String
//   r.stderr    // String
//   r.ok        // code == 0
//
//   // With options
//   var r = Proc.run(["git", "status"], {
//     "cwd":     "/some/dir",
//     "env":     {"GIT_AUTHOR_NAME": "alice"},
//     "stdin":   "data on stdin\n",
//     "timeout": 30
//   })
//
//   // Shell pipeline (explicit opt-in — avoids shell injection
//   // by default). Equivalent to running `sh -c "…"`.
//   var r = Proc.shell("ls | grep foo")
//
//   // Convenience: aborts on non-zero exit.
//   var out = Proc.check(["git", "rev-parse", "HEAD"]).stdout
//
// The whole command is run synchronously; stdout/stderr must
// fit in memory. Streaming reads are a later upgrade.

import "proc" for ProcCore

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

  ok { _code == 0 && !_timedOut }

  toString {
    var state = _timedOut ? "timed out" : "exit %(_code)"
    return "Result(%(state))"
  }
}

class Proc {
  // Run a command and capture output.
  static run(argv)          { run(argv, {}) }
  static run(argv, options) {
    if (!(argv is List)) Fiber.abort("Proc.run: argv must be a list")
    if (options != null && !(options is Map)) {
      Fiber.abort("Proc.run: options must be a Map")
    }
    if (options == null) options = {}

    var cwd     = options.containsKey("cwd")     ? options["cwd"]     : null
    var env     = options.containsKey("env")     ? options["env"]     : null
    var stdin   = options.containsKey("stdin")   ? options["stdin"]   : null
    var timeout = options.containsKey("timeout") ? options["timeout"] : null

    var raw = ProcCore.run(argv, cwd, env, stdin, timeout)
    return Result.new_(
      raw["code"],
      raw["stdout"],
      raw["stderr"],
      raw["timedOut"]
    )
  }

  // Run a shell command via `sh -c`. Exists to make "I want a
  // pipeline" use cases explicit rather than letting them slip in
  // by accident — callers have to actively choose shell
  // semantics and accept the injection risk that comes with them.
  static shell(cmd)          { shell(cmd, {}) }
  static shell(cmd, options) {
    if (!(cmd is String)) Fiber.abort("Proc.shell: cmd must be a string")
    return run(["sh", "-c", cmd], options)
  }

  // Run a command, abort the fiber if it exits non-zero. Returns
  // the Result on success. Ergonomic when shelling out is a
  // mechanical step — `Proc.check(["git", "pull"])` reads
  // obviously and fails loudly.
  static check(argv)          { check(argv, {}) }
  static check(argv, options) {
    var r = run(argv, options)
    if (!r.ok) {
      var label = argv.count > 0 ? argv[0] : "?"
      if (r.timedOut) {
        Fiber.abort("Proc.check: %(label) timed out")
      }
      Fiber.abort("Proc.check: %(label) exited %(r.code): %(r.stderr)")
    }
    return r
  }
}
