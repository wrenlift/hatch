// `@hatch:color`. Colour primitive with RGBA scalars in `[0, 1]`.
//
// ```wren
// import "@hatch:color" for Color
//
// var fill   = Color.rgb(0.2, 0.6, 0.9)
// var border = Color.hex("#22aaff")
// var faded  = Color.lerp(fill, border, 0.5)
//
// material.albedoColor = fill.toVec4   // hand off to a Vec4-typed sink
// ```
//
// ## Conventions
//
// - Channels are linear-space scalars; convert from sRGB at the
//   boundary (most material slots already do this).
// - `Color` is mutable in place (`c.r = 0.5`) but every binary
//   operation (`lerp`, `scale`, `withAlpha`) returns a fresh
//   instance.
// - `toVec4` is the canonical way to hand a colour to renderer /
//   material APIs that take a raw `Vec4`. `Color` is the
//   author-facing surface; `Vec4` stays the wire format.

import "@hatch:math" for Vec4, Math

/// Colour with RGBA channels in `[0, 1]`. HDR values outside the
/// range are valid (named constructors clamp where it matters).
class Color {
  /// Build a colour from individual scalar channels in `[0, 1]`.
  /// Channels are NOT clamped — HDR sources can use values > 1.
  ///
  /// @param {Num} r
  /// @param {Num} g
  /// @param {Num} b
  /// @param {Num} a
  construct new(r, g, b, a) {
    _r = r
    _g = g
    _b = b
    _a = a
  }

  /// Opaque RGB shortcut — alpha defaults to 1.
  static rgb(r, g, b) { Color.new(r, g, b, 1) }

  /// Full RGBA constructor — same shape as `Color.new`, named
  /// for symmetry with `rgb`.
  static rgba(r, g, b, a) { Color.new(r, g, b, a) }

  /// HSV → RGB with hue in `[0, 1]` (NOT degrees). Saturation
  /// and value clamp to `[0, 1]`. Useful for procedural palette
  /// generation (rainbow gradients, jittered tints).
  ///
  /// @param {Num} h. Hue in `[0, 1]` — wraps cyclically.
  /// @param {Num} s. Saturation in `[0, 1]`.
  /// @param {Num} v. Value / brightness in `[0, 1]`.
  static hsv(h, s, v) { Color.hsva(h, s, v, 1) }

  /// HSV → RGB with explicit alpha. See `hsv` for hue convention.
  static hsva(h, s, v, a) {
    var hh = ((h % 1) + 1) % 1
    var ss = Math.saturate(s)
    var vv = Math.saturate(v)
    if (ss == 0) return Color.new(vv, vv, vv, a)
    var i  = (hh * 6).floor
    var f  = hh * 6 - i
    var p  = vv * (1 - ss)
    var q  = vv * (1 - ss * f)
    var t  = vv * (1 - ss * (1 - f))
    if (i == 0) return Color.new(vv, t, p, a)
    if (i == 1) return Color.new(q, vv, p, a)
    if (i == 2) return Color.new(p, vv, t, a)
    if (i == 3) return Color.new(p, q, vv, a)
    if (i == 4) return Color.new(t, p, vv, a)
    return Color.new(vv, p, q, a)
  }

  /// Parse a `#rgb`, `#rrggbb`, or `#rrggbbaa` hex literal. The
  /// leading `#` is optional. Channels decode from `[0, 255]`
  /// to `[0, 1]`. Aborts on malformed input — this is the right
  /// behaviour for hard-coded palette constants where a typo is
  /// a compile-time-class problem.
  ///
  /// @param {String} s
  static hex(s) {
    var t = s
    if (t.count > 0 && t[0] == "#") t = t[1..-1]
    var n = t.count
    if (n == 3) {
      var r = Color.hexNibble_(t[0])
      var g = Color.hexNibble_(t[1])
      var b = Color.hexNibble_(t[2])
      return Color.new((r * 17) / 255, (g * 17) / 255, (b * 17) / 255, 1)
    }
    if (n == 6 || n == 8) {
      var r = Color.hexByte_(t, 0)
      var g = Color.hexByte_(t, 2)
      var b = Color.hexByte_(t, 4)
      var a = n == 8 ? Color.hexByte_(t, 6) / 255 : 1
      return Color.new(r / 255, g / 255, b / 255, a)
    }
    Fiber.abort("Color.hex: expected #rgb / #rrggbb / #rrggbbaa, got %(s)")
  }

  static hexNibble_(c) {
    var code = c.bytes[0]
    if (code >= 48 && code <= 57) return code - 48           // 0-9
    if (code >= 97 && code <= 102) return code - 97 + 10     // a-f
    if (code >= 65 && code <= 70) return code - 65 + 10      // A-F
    Fiber.abort("Color.hex: invalid hex char %(c)")
  }

  static hexByte_(s, i) {
    return Color.hexNibble_(s[i]) * 16 + Color.hexNibble_(s[i + 1])
  }

  // Named constants — opt-in convenience, not exhaustive. Extend
  // via a palette-pack package downstream if you need ANSI / Tab10
  // / CSS named colour sets.
  static white       { Color.new(1, 1, 1, 1) }
  static black       { Color.new(0, 0, 0, 1) }
  static red         { Color.new(1, 0, 0, 1) }
  static green       { Color.new(0, 1, 0, 1) }
  static blue        { Color.new(0, 0, 1, 1) }
  static yellow      { Color.new(1, 1, 0, 1) }
  static cyan        { Color.new(0, 1, 1, 1) }
  static magenta     { Color.new(1, 0, 1, 1) }
  static transparent { Color.new(0, 0, 0, 0) }

  r { _r }
  g { _g }
  b { _b }
  a { _a }
  r=(v) { _r = v }
  g=(v) { _g = v }
  b=(v) { _b = v }
  a=(v) { _a = v }

  /// Component-wise linear interpolation. `t = 0` returns `a`,
  /// `t = 1` returns `b`. `t` outside `[0, 1]` extrapolates.
  ///
  /// @param {Color} a
  /// @param {Color} b
  /// @param {Num}   t
  static lerp(a, b, t) {
    return Color.new(
      a.r + (b.r - a.r) * t,
      a.g + (b.g - a.g) * t,
      a.b + (b.b - a.b) * t,
      a.a + (b.a - a.a) * t)
  }

  /// Returns a `Vec4` with the same RGBA channels — for handing
  /// off to renderer / material APIs that take a raw `Vec4`.
  toVec4 { Vec4.new(_r, _g, _b, _a) }

  /// Scales RGB by `s` while preserving alpha. Common for tinting.
  ///
  /// @param {Num} s
  scale(s) { Color.new(_r * s, _g * s, _b * s, _a) }

  /// Returns this colour with a new alpha channel.
  ///
  /// @param {Num} a
  withAlpha(a) { Color.new(_r, _g, _b, a) }

  approxEq(o) { approxEq(o, 1e-6) }
  approxEq(o, eps) {
    return (_r - o.r).abs <= eps &&
           (_g - o.g).abs <= eps &&
           (_b - o.b).abs <= eps &&
           (_a - o.a).abs <= eps
  }

  ==(o) { o is Color && _r == o.r && _g == o.g && _b == o.b && _a == o.a }
  !=(o) { !(this == o) }
  hash  { Vec4.new(_r, _g, _b, _a).hash }
  toString { "Color(%(_r), %(_g), %(_b), %(_a))" }
}
