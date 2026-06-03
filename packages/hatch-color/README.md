# @hatch:color

Colour primitive with RGBA scalars in `[0, 1]`. Builds on `@hatch:math`
for `Vec4` interop. Use this anywhere a renderer / material / HUD
accepts colour values — `Color` carries the named constructors,
constants, and conversions that raw `Vec4` doesn't.

## Quick start

```wren
import "@hatch:color" for Color

var fill   = Color.rgb(0.2, 0.6, 0.9)
var border = Color.hex("#22aaff")
var faded  = Color.lerp(fill, border, 0.5)
var warm   = Color.hsv(0.08, 0.6, 0.9)

// Hand off to a Vec4-typed material slot.
material.albedoColor = fill.toVec4
```

## Constructors

- `Color.new(r, g, b, a)` — raw scalar channels.
- `Color.rgb(r, g, b)` — opaque shorthand, alpha = 1.
- `Color.rgba(r, g, b, a)` — same as `new`, reads better in `Color.rgba(...)`.
- `Color.hsv(h, s, v)` / `Color.hsva(h, s, v, a)` — HSV → RGB. Hue is
  `[0, 1]` (not degrees) and wraps cyclically.
- `Color.hex(s)` — parses `#rgb` / `#rrggbb` / `#rrggbbaa` (leading
  `#` optional). Aborts on malformed input.

## Named constants

`Color.white`, `Color.black`, `Color.red`, `Color.green`, `Color.blue`,
`Color.yellow`, `Color.cyan`, `Color.magenta`, `Color.transparent`.

## Operations

- `Color.lerp(a, b, t)` — component-wise linear interpolation.
- `c.scale(s)` — scales RGB; alpha preserved.
- `c.withAlpha(a)` — copy with a new alpha.
- `c.toVec4` — `Vec4` for handoff to renderer / material APIs.
- `c.approxEq(o[, eps])` — fuzzy equality.

## Conventions

- All channels are linear-space scalars in `[0, 1]`. HDR values
  outside the range are valid (e.g. `Color.new(2.2, 2.2, 2.3, 1)`
  for an overbright surface).
- `==` is exact bit-equality; use `approxEq` for fuzzy compares.
- Author-facing surface is `Color`; wire format stays `Vec4`.
  Convert via `c.toVec4` at the boundary.
