// `@hatch:os` — process-level primitives.
//
// ```wren
// import "@hatch:os" for Os
//
// Os.platform                   // "macos" / "linux" / "windows" / …
// Os.arch                       // "aarch64" / "x86_64" / …
// Os.isUnix                     // convenience flag
// Os.isWindows
//
// Os.env("HOME")                // String or null
// Os.env("PORT", "8080")        // fetch with default
// Os.setEnv("KEY", "value")
// Os.unsetEnv("KEY")
// Os.envMap                     // Map<String, String> snapshot
//
// Os.args                       // List<String>, first is the program
// Os.argv                       // alias, skips the program name
//
// Os.isatty(Os.STDOUT)          // Bool
// Os.STDIN / STDOUT / STDERR    // 0 / 1 / 2
//
// Os.username                   // best-effort via $USER / $USERNAME
// Os.exit(0)                    // never returns
// ```
//
// Backed by the runtime `os` module. Exists so consumers don't
// need to know whether a given feature is native or pure-Wren —
// the boundary shifts as the runtime grows.

import "os" for OS

class Os {
  /// -- Platform ----------------------------------------------------------

  static platform { OS.platform }
  static arch     { OS.arch }
  static isUnix   { platform != "windows" }
  static isWindows { platform == "windows" }

  // -- Env ---------------------------------------------------------------

  /// Single-arg form: the raw value or null.
  static env(name) { OS.env(name) }

  /// Two-arg form: fallback when the var is unset. Saves callers
  /// from writing `Os.env("X") || "default"` at every callsite.
  static env(name, default_) {
    var v = OS.env(name)
    return v == null ? default_ : v
  }

  static setEnv(name, value) { OS.setEnv(name, value) }
  static unsetEnv(name) { OS.unsetEnv(name) }
  static envMap { OS.envMap }

  /// -- Args --------------------------------------------------------------

  static args { OS.args }

  /// argv: the args _without_ the program name, matching how
  /// @hatch:cli and most other CLI code want it.
  static argv {
    var all = OS.args
    if (all.count == 0) return []
    return all[1...all.count]
  }

  /// -- TTY ---------------------------------------------------------------

  static STDIN  { 0 }
  static STDOUT { 1 }
  static STDERR { 2 }

  static isatty(fd) { OS.isatty(fd) }

  /// -- Identity ----------------------------------------------------------

  static username { OS.username }

  /// -- Exit --------------------------------------------------------------

  static exit(code) { OS.exit(code) }
}
