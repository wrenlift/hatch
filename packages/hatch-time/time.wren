// `@hatch:time`: clocks and UTC timestamp formatting.
//
// ```wren
// import "@hatch:time" for Time, Clock
//
// // Clocks
// Clock.unix                    // Num seconds since 1970-01-01
// Clock.mono                    // Num monotonic seconds (for
//                               // durations, not wall-clock)
// Clock.sleep(0.5)              // block 500ms
// Clock.sleepMs(250)
//
// var elapsed = Clock.elapsed {
//   doWork()
// }                             // Num seconds
//
// // Point in time (instances of Time)
// var t = Time.now              // now
// var t = Time.fromUnix(1776700800)
//
// t.year / t.month / t.day
// t.hour / t.minute / t.second
// t.millisecond / t.weekday     // weekday: 0=Mon … 6=Sun
// t.unix                        // Num seconds since epoch
// t.iso                         // "2026-04-20T00:00:00Z"
// t.format("YYYY-MM-DD HH:mm:ss")
// ```
//
// UTC only for v0.1. Localtime needs tz data we don't ship yet.

import "time" for TimeCore

/// Re-exports under the same name. Gives callers a single import
/// surface without pulling the raw "time" module themselves.
class Clock {
  static unix { TimeCore.unix }
  static mono { TimeCore.mono }
  static sleep(seconds) { TimeCore.sleep(seconds) }
  static sleepMs(ms)    { TimeCore.sleep(ms / 1000) }

  /// Time a block. Returns monotonic seconds elapsed.
  static elapsed(block) {
    if (!(block is Fn)) Fiber.abort("Clock.elapsed: expected a Fn")
    var start = TimeCore.mono
    block.call()
    return TimeCore.mono - start
  }
}

class Time {
  // Factory constructors -------------------------------------------------

  /// Capture the current moment.
  static now { fromUnix(TimeCore.unix) }

  /// Wrap a Unix timestamp (seconds since 1970-01-01 UTC).
  static fromUnix(seconds) {
    if (!(seconds is Num)) Fiber.abort("Time.fromUnix: expected a number")
    return new_(seconds)
  }

  construct new_(seconds) {
    _unix = seconds
    _c = TimeCore.utc(seconds)
  }

  /// Component getters ----------------------------------------------------

  unix         { _unix }
  year         { _c["year"] }
  month        { _c["month"] }
  day          { _c["day"] }
  hour         { _c["hour"] }
  minute       { _c["minute"] }
  second       { _c["second"] }
  millisecond  { _c["millisecond"] }
  weekday      { _c["weekday"] }

  // Formatting -----------------------------------------------------------

  /// RFC 3339 / ISO 8601 in UTC, e.g. "2026-04-20T14:23:45Z".
  iso {
    return "%(Time.pad_(year, 4))-%(Time.pad_(month, 2))-%(Time.pad_(day, 2))" +
           "T%(Time.pad_(hour, 2)):%(Time.pad_(minute, 2)):%(Time.pad_(second, 2))Z"
  }

  /// Custom format. Tokens: YYYY, MM, DD, HH, mm, ss, SSS (millis).
  /// Everything else passes through verbatim. Minimal on purpose;
  /// full strftime is a later upgrade.
  format(pattern) {
    if (!(pattern is String)) Fiber.abort("Time.format: pattern must be a string")
    var out = pattern
    out = out.replace("YYYY", Time.pad_(year, 4))
    out = out.replace("MM",   Time.pad_(month, 2))
    out = out.replace("DD",   Time.pad_(day, 2))
    out = out.replace("HH",   Time.pad_(hour, 2))
    out = out.replace("mm",   Time.pad_(minute, 2))
    out = out.replace("ss",   Time.pad_(second, 2))
    out = out.replace("SSS",  Time.pad_(millisecond, 3))
    return out
  }

  toString { iso }
  toJson() { iso }

  // Helpers --------------------------------------------------------------

  // Left-pad `n` with zeros to at least `width`. Pure Wren;
  // no String.format machinery in the core. Static so the
  // formatters can reach it via `Time.pad_(...)`.
  static pad_(n, width) {
    var s = "%(n.truncate)"
    if (n < 0) {
      var body = s[1...s.count]
      while (body.count < width) body = "0" + body
      return "-" + body
    }
    while (s.count < width) s = "0" + s
    return s
  }
}
