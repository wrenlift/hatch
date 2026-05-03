A timezone-aware `DateTime` value type with `Duration` arithmetic, RFC 3339 parse and format. Layers on top of `@hatch:time`'s UTC-only unix-seconds primitive: this package adds offsets, calendar fields, parsing, formatting, and span arithmetic. Comparisons and equality work against the underlying UTC instant, so two `DateTime`s with different offsets but the same moment compare equal.

## Overview

`DateTime` is immutable. Construct from `now`, from explicit UTC components, or by parsing an RFC 3339 string. Arithmetic with a `Duration` returns a fresh `DateTime` rather than mutating in place.

```wren
import "@hatch:datetime" for DateTime, Duration

var now = DateTime.now
var t   = DateTime.utc(2026, 4, 21, 15, 30)
var p   = DateTime.parse("2026-04-21T15:30:00+02:00")

System.print(t.iso)                                   // 2026-04-21T15:30:00Z
System.print(t.format("YYYY-MM-DD HH:mm:ss ZZ"))      // 2026-04-21 15:30:00 +0000

var later   = t.add(Duration.hours(2))
var between = later.diff(t)
System.print(between.minutes)                          // 120

System.print(
  DateTime.parse("2026-01-01T12:00:00+00:00") ==
  DateTime.parse("2026-01-01T13:00:00+01:00"))         // true
```

`Duration` stores seconds internally and exposes coarser views (`seconds`, `minutes`, `hours`, `days`). It supports `+`, `-`, unary negation, and scalar `*`; comparisons go through the stored seconds value.

## Working with offsets

`dt.offsetMinutes` is the signed minutes-from-UTC the local fields render at (`0` for UTC, `60` for `+01:00`, `-300` for `-05:00`). Calendar getters (`year`, `month`, `day`, `hour`, `minute`, `second`, `weekday`) reflect the offset; the underlying instant doesn't move when you change it.

> **Note: no IANA tz database**
> The package handles fixed UTC offsets, not named zones like `America/New_York`. DST transitions and historical zone changes aren't modelled here. When those are needed, parse and format at the boundary and do business logic in UTC.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Depends on `@hatch:time` for the unix-seconds primitive. Pure-Wren calendar math; works on every supported target.
