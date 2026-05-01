// `@hatch:datetime` — timezone-aware `DateTime` + `Duration`
// arithmetic.
//
// ```wren
// import "@hatch:datetime" for DateTime, Duration
//
// DateTime.now                              // now, UTC
// DateTime.utc(2026, 4, 21, 15, 30)         // 2026-04-21T15:30:00Z
// DateTime.parse("2026-04-21T15:30:00+02:00")
//
// var dt = DateTime.now
// dt.year / dt.month / dt.day
// dt.hour / dt.minute / dt.second
// dt.weekday            // 0=Mon … 6=Sun
// dt.offsetMinutes      // signed int; 0 for UTC, 60 for +01:00
// dt.iso                // "2026-04-21T15:30:00+02:00" / "…Z"
// dt.format("YYYY-MM-DD HH:mm:ss ZZ")
//
// // Arithmetic returns fresh DateTime values.
// var later    = dt.add(Duration.hours(2))
// var earlier  = dt.subtract(Duration.minutes(15))
// var between  = later.diff(earlier)             // → Duration
// between.seconds                                // Num (integer)
// between.minutes                                // fractional Num
//
// // Compare by the underlying UTC instant — offset doesn't matter.
// DateTime.parse("2026-01-01T12:00:00+00:00") ==
//   DateTime.parse("2026-01-01T13:00:00+01:00")       // true
// ```
//
// `@hatch:time`'s `Time` is UTC-only and wraps a raw unix `Num`;
// this package layers a real value-type on top with offsets,
// parsing, calendar math, and a `Duration` companion. Builds on
// `TimeCore.utc(seconds)` from the runtime `time` module for the
// unix → components direction; the reverse (components → unix)
// is pure Wren via the civil-from-days algorithm.

import "time" for TimeCore

// --- Duration ---------------------------------------------------------------

/// A span of time. Internally stored as seconds (can be
/// fractional and negative). Constructors let you express common
/// units:
///
/// ```wren
/// Duration.seconds(30)
/// Duration.minutes(1.5)
/// Duration.hours(24)
/// Duration.days(7)
/// ```
///
/// Read back as either the stored unit or any coarser/finer one:
///
/// ```wren
/// d.seconds / d.minutes / d.hours / d.days
/// ```
class Duration {
  construct new_(secs) {
    _s = secs
  }

  static seconds(n) {
    if (!(n is Num)) Fiber.abort("Duration.seconds: expected a number")
    return Duration.new_(n)
  }
  static minutes(n) {
    if (!(n is Num)) Fiber.abort("Duration.minutes: expected a number")
    return Duration.new_(n * 60)
  }
  static hours(n) {
    if (!(n is Num)) Fiber.abort("Duration.hours: expected a number")
    return Duration.new_(n * 3600)
  }
  static days(n) {
    if (!(n is Num)) Fiber.abort("Duration.days: expected a number")
    return Duration.new_(n * 86400)
  }

  seconds { _s }
  minutes { _s / 60 }
  hours   { _s / 3600 }
  days    { _s / 86400 }

  // --- Arithmetic --------------------------------------------------
  +(other) {
    if (!(other is Duration)) Fiber.abort("Duration +: expected a Duration")
    return Duration.new_(_s + other.seconds)
  }
  -(other) {
    if (!(other is Duration)) Fiber.abort("Duration -: expected a Duration")
    return Duration.new_(_s - other.seconds)
  }
  -     { Duration.new_(-_s) }
  *(n)  {
    if (!(n is Num)) Fiber.abort("Duration *: expected a Num")
    return Duration.new_(_s * n)
  }

  // --- Comparison --------------------------------------------------
  ==(other) { other is Duration && _s == other.seconds }
  !=(other) { !(this == other) }
  <(other)  { other is Duration && _s <  other.seconds }
  <=(other) { other is Duration && _s <= other.seconds }
  >(other)  { other is Duration && _s >  other.seconds }
  >=(other) { other is Duration && _s >= other.seconds }

  toString {
    // Pick the most human unit for the display — keeps debug output
    // readable without losing precision.
    if (_s.abs >= 86400) return "%(days)d"
    if (_s.abs >= 3600)  return "%(hours)h"
    if (_s.abs >= 60)    return "%(minutes)m"
    return "%(_s)s"
  }
}

// --- DateTime ---------------------------------------------------------------

class DateTime {
  // Internal: _unix is seconds since 1970-01-01T00:00:00Z (a real
  // UTC instant). _off is the offset in minutes that the LOCAL
  // fields should be displayed at. Two DateTimes with the same
  // instant but different offsets are equal (same point in time).
  construct new_(unix, offsetMinutes) {
    _unix = unix
    _off  = offsetMinutes
    // Pre-compute component getters — cached to avoid calling
    // TimeCore.utc on every .year / .month / .day access.
    _c = TimeCore.utc(unix + offsetMinutes * 60)
  }

  // --- Factory constructors ----------------------------------------

  static now { fromUnix(TimeCore.unix) }

  static fromUnix(seconds) {
    if (!(seconds is Num)) Fiber.abort("DateTime.fromUnix: expected a number")
    return DateTime.new_(seconds, 0)
  }

  static fromUnix(seconds, offsetMinutes) {
    if (!(seconds is Num)) Fiber.abort("DateTime.fromUnix: seconds must be a number")
    if (!(offsetMinutes is Num) || !offsetMinutes.isInteger) {
      Fiber.abort("DateTime.fromUnix: offsetMinutes must be an integer")
    }
    return DateTime.new_(seconds, offsetMinutes)
  }

  /// Construct at an explicit UTC moment.
  static utc(year, month, day) {
    return utc(year, month, day, 0, 0, 0)
  }
  static utc(year, month, day, hour, minute, second) {
    var s = DateTime.daysFromCivil_(year, month, day) * 86400 +
            hour * 3600 + minute * 60 + second
    return DateTime.new_(s, 0)
  }

  /// RFC 3339 parser: `YYYY-MM-DDTHH:MM:SS(.fff)?(Z|±HH:MM)`.
  /// Permissive about the separator (`T` or space).
  static parse(text) {
    if (!(text is String)) Fiber.abort("DateTime.parse: text must be a string")
    return Parser_.parse_(text)
  }

  // --- Component getters -------------------------------------------

  unix          { _unix }
  offsetMinutes { _off }
  year          { _c["year"] }
  month         { _c["month"] }
  day           { _c["day"] }
  hour          { _c["hour"] }
  minute        { _c["minute"] }
  second        { _c["second"] }
  millisecond   { _c["millisecond"] }
  weekday       { _c["weekday"] }

  // --- Formatting --------------------------------------------------

  /// RFC 3339 form. Includes the offset as `Z` for UTC or `±HH:MM`.
  iso {
    var base =
      "%(DateTime.pad_(year, 4))-%(DateTime.pad_(month, 2))-%(DateTime.pad_(day, 2))" +
      "T%(DateTime.pad_(hour, 2)):%(DateTime.pad_(minute, 2)):%(DateTime.pad_(second, 2))"
    return base + offsetSuffix_
  }

  /// Custom format. Tokens extend `Time.format`:
  ///
  /// | Token                       | Meaning                          |
  /// |-----------------------------|----------------------------------|
  /// | `YYYY MM DD HH mm ss SSS`   | Same as `@hatch:time`.           |
  /// | `Z`                         | `Z` for UTC, `±HHMM` otherwise.  |
  /// | `ZZ`                        | `±HH:MM` (or `Z` for UTC).       |
  format(pattern) {
    if (!(pattern is String)) Fiber.abort("DateTime.format: pattern must be a string")
    var out = pattern
    // Longer tokens first so `SSS` doesn't eat `SS`, `ZZ` doesn't eat `Z`.
    out = out.replace("YYYY", DateTime.pad_(year, 4))
    out = out.replace("SSS",  DateTime.pad_(millisecond, 3))
    out = out.replace("MM",   DateTime.pad_(month,  2))
    out = out.replace("DD",   DateTime.pad_(day,    2))
    out = out.replace("HH",   DateTime.pad_(hour,   2))
    out = out.replace("mm",   DateTime.pad_(minute, 2))
    out = out.replace("ss",   DateTime.pad_(second, 2))
    out = out.replace("ZZ",   offsetSuffix_)
    out = out.replace("Z",    offsetCompact_)
    return out
  }

  offsetSuffix_ {
    if (_off == 0) return "Z"
    var sign = _off > 0 ? "+" : "-"
    var mag = _off.abs
    var h = (mag / 60).floor
    var m = mag - h * 60
    return "%(sign)%(DateTime.pad_(h, 2)):%(DateTime.pad_(m, 2))"
  }

  // Compact form: "Z" or "±HHMM" (no colon).
  offsetCompact_ {
    if (_off == 0) return "Z"
    var sign = _off > 0 ? "+" : "-"
    var mag = _off.abs
    var h = (mag / 60).floor
    var m = mag - h * 60
    return "%(sign)%(DateTime.pad_(h, 2))%(DateTime.pad_(m, 2))"
  }

  // --- Arithmetic --------------------------------------------------

  /// Add a Duration and return a new DateTime at the same offset.
  add(d) {
    if (!(d is Duration)) Fiber.abort("DateTime.add: expected a Duration")
    return DateTime.new_(_unix + d.seconds, _off)
  }

  /// Subtract a Duration OR compute a Duration between two DateTimes.
  subtract(other) {
    if (other is Duration) return DateTime.new_(_unix - other.seconds, _off)
    if (other is DateTime) return Duration.new_(_unix - other.unix)
    Fiber.abort("DateTime.subtract: expected a Duration or DateTime")
  }

  /// Alias for `subtract` when both sides are DateTimes — reads
  /// nicer in time-between-events contexts.
  diff(other) {
    if (!(other is DateTime)) Fiber.abort("DateTime.diff: expected a DateTime")
    return Duration.new_(_unix - other.unix)
  }

  /// Return a new DateTime representing the same instant but in a
  /// different wall-clock offset. Useful for "what time is it in
  /// New York right now" given a UTC clock.
  withOffset(offsetMinutes) {
    if (!(offsetMinutes is Num) || !offsetMinutes.isInteger) {
      Fiber.abort("DateTime.withOffset: offsetMinutes must be an integer")
    }
    return DateTime.new_(_unix, offsetMinutes)
  }

  toUtc { withOffset(0) }

  // --- Comparison --------------------------------------------------
  // Always by UTC instant. Two DateTimes at the same moment
  // but different offsets compare equal — they're the same
  // point in time just described differently.

  ==(other) { other is DateTime && _unix == other.unix }
  !=(other) { !(this == other) }
  <(other)  { other is DateTime && _unix <  other.unix }
  <=(other) { other is DateTime && _unix <= other.unix }
  >(other)  { other is DateTime && _unix >  other.unix }
  >=(other) { other is DateTime && _unix >= other.unix }

  toString { iso }
  toJson() { iso }

  // --- Calendar helpers --------------------------------------------

  // Howard Hinnant's civil_from_days inverse. Returns the number
  // of days since the Unix epoch (1970-01-01) for the given
  // proleptic-Gregorian date. Correct for any y, m ∈ 1..12,
  // d ∈ 1..31.
  static daysFromCivil_(y, m, d) {
    var yy = m <= 2 ? y - 1 : y
    var era = (yy >= 0 ? yy : yy - 399) / 400
    era = era.floor
    var yoe = yy - era * 400                                            // [0, 399]
    var doy = ((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5).floor + d - 1   // [0, 365]
    var doe = yoe * 365 + (yoe / 4).floor - (yoe / 100).floor + doy     // [0, 146096]
    return era * 146097 + doe - 719468
  }

  // Left-pad `n` with zeros. Mirrors `@hatch:time`'s `Time.pad_`
  // so formatters across the two packages agree.
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

// --- Parser -----------------------------------------------------------------

class Parser_ {
  static parse_(text) {
    var i = 0
    var n = text.count

    // Expect `YYYY-MM-DD`.
    var year   = readInt_(text, i, 4)
        i = i + 4
    expect_(text, i, "-")
        i = i + 1
    var month  = readInt_(text, i, 2)
        i = i + 2
    expect_(text, i, "-")
        i = i + 1
    var day    = readInt_(text, i, 2)
        i = i + 2

    // Optional time part. RFC 3339 requires `T`; we also accept a
    // plain space for readability / human-entered inputs.
    var hour = 0
    var minute = 0
    var second = 0
    if (i < n && (text[i] == "T" || text[i] == "t" || text[i] == " ")) {
      i = i + 1
      hour   = readInt_(text, i, 2)
        i = i + 2
      expect_(text, i, ":")
        i = i + 1
      minute = readInt_(text, i, 2)
        i = i + 2
      expect_(text, i, ":")
        i = i + 1
      second = readInt_(text, i, 2)
        i = i + 2
      // Drop fractional seconds — we keep integer precision in
      // the unix timestamp. They're skipped silently so JSON
      // emitted from other languages parses without surprise.
      if (i < n && text[i] == ".") {
        i = i + 1
        while (i < n && isDigit_(text[i])) i = i + 1
      }
    }

    // Optional offset: `Z`, `z`, or `±HH:MM` / `±HHMM`.
    var offset = 0
    if (i < n) {
      var c = text[i]
      if (c == "Z" || c == "z") {
        i = i + 1
      } else if (c == "+" || c == "-") {
        var sign = c == "+" ? 1 : -1
        i = i + 1
        var oh = readInt_(text, i, 2)
        i = i + 2
        if (i < n && text[i] == ":") i = i + 1
        var om = readInt_(text, i, 2)
        i = i + 2
        offset = sign * (oh * 60 + om)
      }
    }

    if (i != n) {
      Fiber.abort("DateTime.parse: trailing characters at offset %(i)")
    }

    // Compute UTC unix from local components + offset.
    var localSeconds =
      DateTime.daysFromCivil_(year, month, day) * 86400 +
      hour * 3600 + minute * 60 + second
    // `offset` is how far the LOCAL time is ahead of UTC. Subtract
    // to get UTC.
    var unix = localSeconds - offset * 60
    return DateTime.new_(unix, offset)
  }

  static readInt_(s, at, len) {
    if (at + len > s.count) {
      Fiber.abort("DateTime.parse: unexpected end of input at offset %(at)")
    }
    var sum = 0
    var i = 0
    while (i < len) {
      var c = s[at + i]
      if (!isDigit_(c)) {
        Fiber.abort("DateTime.parse: expected a digit at offset %(at + i), got '%(c)'")
      }
      sum = sum * 10 + digitValue_(c)
      i = i + 1
    }
    return sum
  }

  static expect_(s, at, ch) {
    if (at >= s.count || s[at] != ch) {
      Fiber.abort("DateTime.parse: expected '%(ch)' at offset %(at)")
    }
  }

  static isDigit_(c) {
    return c == "0" || c == "1" || c == "2" || c == "3" || c == "4" ||
           c == "5" || c == "6" || c == "7" || c == "8" || c == "9"
  }

  static digitValue_(c) {
    if (c == "0") return 0
    if (c == "1") return 1
    if (c == "2") return 2
    if (c == "3") return 3
    if (c == "4") return 4
    if (c == "5") return 5
    if (c == "6") return 6
    if (c == "7") return 7
    if (c == "8") return 8
    return 9
  }
}
