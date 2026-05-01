// `@hatch:log` — level-filtered logger.
//
// ```wren
// import "@hatch:log" for Log
//
// Log.info("server starting on port %(port)")
// Log.warn("config missing, using defaults")
// Log.error("connection lost")
// Log.debug("cache hit key=%(k)")
// ```
//
// Levels (lowest → highest): `debug`, `info`, `warn`, `error`.
// Set `Log.level = Log.DEBUG` to see everything, `Log.WARN` to
// hide info / debug, etc. Default is `INFO`.
//
// Customise output:
//
// ```wren
// Log.writer = Fn.new { |line| ... }   // pipe somewhere else
// Log.color = false                    // strip ANSI codes
// Log.prefix = "[api] "                // tag every line
// ```
//
// Format is `LEVEL <prefix>message` with the level tag colored
// via `@hatch:fmt` (cyan / green / yellow / red). One line per
// call — callers with multi-line payloads split or interpolate.

import "@hatch:fmt" for Fmt

class Log {
  /// Level constants. Public so callers can do
  /// `Log.level = Log.WARN` without needing to memorise the int.
  static DEBUG { 0 }
  static INFO  { 1 }
  static WARN  { 2 }
  static ERROR { 3 }

  // --- State accessors ----------------------------------------------------

  static level {
    if (__level == null) __level = 1    // INFO
    return __level
  }
  static level=(v) {
    if (!(v is Num) || v < 0 || v > 3) {
      Fiber.abort("Log.level must be one of DEBUG (0) … ERROR (3)")
    }
    __level = v
  }

  static color {
    if (__color == null) __color = true
    return __color
  }
  static color=(v) { __color = v == true }

  static writer {
    if (__writer == null) {
      __writer = Fn.new { |line| System.print(line) }
    }
    return __writer
  }
  static writer=(fn) {
    if (!(fn is Fn)) Fiber.abort("Log.writer must be a Fn")
    __writer = fn
  }

  static prefix {
    if (__prefix == null) __prefix = ""
    return __prefix
  }
  static prefix=(v) {
    if (!(v is String)) Fiber.abort("Log.prefix must be a string")
    __prefix = v
  }

  // --- Level methods ------------------------------------------------------

  static debug(msg) { emit_(DEBUG, msg) }
  static info(msg)  { emit_(INFO,  msg) }
  static warn(msg)  { emit_(WARN,  msg) }
  static error(msg) { emit_(ERROR, msg) }

  // --- Internals ----------------------------------------------------------

  static emit_(lvl, msg) {
    if (lvl < level) return
    var tag = tagFor_(lvl)
    var line = tag + " " + prefix + "%(msg)"
    writer.call(line)
  }

  // Fixed-width tag so messages line up in a typical terminal.
  // Color applied conditionally so `Log.color = false` produces
  // clean text for log files / CI output.
  static tagFor_(lvl) {
    var raw
    if (lvl == DEBUG) {
      raw = "DEBUG"
    } else if (lvl == INFO) {
      raw = "INFO "
    } else if (lvl == WARN) {
      raw = "WARN "
    } else {
      raw = "ERROR"
    }
    if (!color) return raw
    if (lvl == DEBUG) return Fmt.cyan(raw)
    if (lvl == INFO) return Fmt.green(raw)
    if (lvl == WARN) return Fmt.yellow(raw)
    return Fmt.red(raw)
  }
}
