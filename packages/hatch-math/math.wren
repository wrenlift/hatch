// `@hatch:math` — vectors, matrices, quaternions, easings.
//
// ```wren
// import "@hatch:math" for Vec2, Vec3, Vec4, Mat4, Quat, Math, Ease
//
// var p   = Vec3.new(1, 2, 3)
// var v   = Vec3.new(0, 9.8, 0)
// var dt  = 0.016
// var pNext = p + v * dt
//
// var m = Mat4.translation(1, 0, 0) * Mat4.rotationY(Math.PI / 4)
// var q = Quat.fromAxisAngle(Vec3.unitY, Math.PI / 2)
//
// var eased = Ease.inOutQuad(0.35)
// ```
//
// ## Conventions
//
// - Row-major `Mat4` storage — `m.at(row, col)` /
//   `m.set(row, col, v)`.
// - Right-handed coordinates with OpenGL-style clip space
//   (`-1..1` depth, `y` up) for `Mat4.perspective` and `lookAt`.
// - All factory names spell out intent — `Vec3.unitY` rather
//   than `Vec3.up`, `Mat4.rotationX` rather than `Mat4.rx`.
// - Every binary op (`+`, `*`, etc.) returns a fresh instance.
//   For hot loops with fixed buffers, every type exposes
//   in-place companions: `addInto(a, b)`, `mulInto(a, s)` etc.,
//   which write into `this` without allocating.
// - `==` is exact bit-equality. Use `Math.approxEq(a, b, eps)`
//   or the `approxEq(other[, eps])` method on each type for
//   fuzzy comparison under accumulated floating-point error.

/// Scalar math helpers and constants — `Math.PI`, `Math.TAU`,
/// `Math.lerp(a, b, t)`, `Math.clamp(x, lo, hi)`, etc. Pure
/// Wren, no native deps; precision matches the host's `Num`
/// (double-precision float).
class Math {
  static PI           { 3.141592653589793 }
  static TAU          { 6.283185307179586 }
  static HALF_PI      { 1.5707963267948966 }
  static DEG_TO_RAD   { 0.017453292519943295 }
  static RAD_TO_DEG   { 57.29577951308232 }
  static EPSILON      { 0.000001 }

  static radians(deg) { deg * 0.017453292519943295 }
  static degrees(rad) { rad * 57.29577951308232 }

  /// Linear interpolation from `a` to `b` at `t` in `[0, 1]`. `t`
  /// outside that range extrapolates — `clampedLerp` clamps first.
  static lerp(a, b, t)        { a + (b - a) * t }
  static clampedLerp(a, b, t) { lerp(a, b, Math.clamp(t, 0, 1)) }

  /// Inverse lerp — given a value, return its `t` on the `[a, b]`
  /// axis. Useful for remapping ranges with `lerp(c, d, inv(a, b, v))`.
  static inverseLerp(a, b, v) {
    if (a == b) return 0
    return (v - a) / (b - a)
  }

  static clamp(v, lo, hi) {
    if (v < lo) return lo
    if (v > hi) return hi
    return v
  }

  /// Clamp to `[0, 1]`. Named after the GLSL / HLSL intrinsic.
  static saturate(v)       { Math.clamp(v, 0, 1) }

  /// Hermite smoothstep — zero-slope endpoints at `a` and `b`.
  /// Classic shader / animation staple for ease-in-out curves.
  static smoothstep(a, b, v) {
    var t = Math.saturate(Math.inverseLerp(a, b, v))
    return t * t * (3 - 2 * t)
  }
  /// Higher-order smoothstep (Ken Perlin's — zero second derivative
  /// at endpoints). Smoother still than the cubic version.
  static smootherstep(a, b, v) {
    var t = Math.saturate(Math.inverseLerp(a, b, v))
    return t * t * t * (t * (6 * t - 15) + 10)
  }

  static min(a, b)       { a < b ? a : b }
  static max(a, b)       { a > b ? a : b }
  static sign(v)         { v > 0 ? 1 : (v < 0 ? -1 : 0) }

  /// Floating-point equality with a tolerance.
  static approxEq(a, b)        { approxEq(a, b, 0.000001) }
  static approxEq(a, b, eps)   { (a - b).abs < eps }

  /// Wraps `v` into `[lo, hi)` — handy for angle wrap-around.
  static wrap(v, lo, hi) {
    var range = hi - lo
    if (range <= 0) return lo
    var t = v - lo
    t = t - (t / range).floor * range
    return lo + t
  }
}

// -- Easings ----------------------------------------------------
//
// Classic Robert Penner curves, clamped so `t` outside `[0, 1]`
// produces `0` or `1` respectively. Use as animation / transition
// curves:
//
//   var eased = Ease.outCubic(progress)
//   particle.pos = Vec3.lerp(start, end, eased)

/// Easing curves for animation / transition. Every method
/// takes a `t` in `[0, 1]` and returns the eased progress.
/// Inputs outside `[0, 1]` are clamped via [Math.saturate],
/// so `t = 0` produces `0` and `t = 1` produces `1` for
/// every curve.
///
/// ## Example
///
/// ```wren
/// var eased  = Ease.outCubic(progress)
/// particle.pos = Vec3.lerp(start, end, eased)
/// ```
class Ease {
  static linear(t) { Math.saturate(t) }

  static inQuad(t) {
    var s = Math.saturate(t)
    return s * s
  }
  static outQuad(t) {
    var s = Math.saturate(t)
    return 1 - (1 - s) * (1 - s)
  }
  static inOutQuad(t) {
    var s = Math.saturate(t)
    return s < 0.5 ? 2 * s * s : 1 - (-2 * s + 2) * (-2 * s + 2) / 2
  }

  static inCubic(t) {
    var s = Math.saturate(t)
    return s * s * s
  }
  static outCubic(t) {
    var s = Math.saturate(t)
    var u = 1 - s
    return 1 - u * u * u
  }
  static inOutCubic(t) {
    var s = Math.saturate(t)
    if (s < 0.5) return 4 * s * s * s
    var u = -2 * s + 2
    return 1 - u * u * u / 2
  }

  /// Asymmetric elastic-like overshoot — `t` exits just past 1
  /// before settling back. Gentle pop for bouncy UI transitions.
  static inBack(t) {
    var s = Math.saturate(t)
    return 2.70158 * s * s * s - 1.70158 * s * s
  }
  static outBack(t) {
    var s = Math.saturate(t)
    var u = s - 1
    return 1 + 2.70158 * u * u * u + 1.70158 * u * u
  }

  /// Exponential — strong acceleration / deceleration with
  /// zero-crossing pinned to the endpoints.
  static inExpo(t) {
    var s = Math.saturate(t)
    if (s == 0) return 0
    return 2.pow(10 * (s - 1))
  }
  static outExpo(t) {
    var s = Math.saturate(t)
    if (s == 1) return 1
    return 1 - 2.pow(-10 * s)
  }
}

/// 2-component vector (`x`, `y`). Constructed via
/// [Vec2.new], or one of the factory getters (`Vec2.zero`,
/// `Vec2.one`, …). Operators `+`, `-`, `*`, `/`, `==` work
/// component-wise; methods return new vectors (immutable
/// math is the convention).
class Vec2 {
  /// Factory methods --------------------------------------------------

  construct new(x, y) {
    _x = x
    _y = y
  }

  static zero     { Vec2.new(0, 0) }
  static one      { Vec2.new(1, 1) }
  static unitX    { Vec2.new(1, 0) }
  static unitY    { Vec2.new(0, 1) }

  /// Component accessors ---------------------------------------------
  x { _x }
  y { _y }
  x=(v) { _x = v }
  y=(v) { _y = v }

  // Arithmetic (immutable) ------------------------------------------

  // Binary ops accept either a `Vec2` (component-wise) or a `Num`
  // (broadcast). Keeps `v * 0.5` and `v * u` readable.
  +(other) { other is Vec2 ? Vec2.new(_x + other.x, _y + other.y) : Vec2.new(_x + other, _y + other) }
  -(other) { other is Vec2 ? Vec2.new(_x - other.x, _y - other.y) : Vec2.new(_x - other, _y - other) }
  *(other) { other is Vec2 ? Vec2.new(_x * other.x, _y * other.y) : Vec2.new(_x * other, _y * other) }
  /(other) { other is Vec2 ? Vec2.new(_x / other.x, _y / other.y) : Vec2.new(_x / other, _y / other) }
  - { Vec2.new(-_x, -_y) }

  /// Length / normalization ------------------------------------------

  lengthSq { _x * _x + _y * _y }
  length   { lengthSq.sqrt }

  normalized {
    var l = length
    if (l == 0) return Vec2.zero
    return Vec2.new(_x / l, _y / l)
  }

  /// Dot product + angle / distance ----------------------------------

  dot(other)        { _x * other.x + _y * other.y }
  distanceSq(other) {
    var dx = _x - other.x
    var dy = _y - other.y
    return dx * dx + dy * dy
  }
  distance(other)   { distanceSq(other).sqrt }
  /// Right-hand 2D cross — returns the scalar z-component as if
  /// the vectors had z=0. Useful for signed area / winding.
  cross(other)      { _x * other.y - _y * other.x }

  /// Interpolation ---------------------------------------------------

  static lerp(a, b, t) { Vec2.new(Math.lerp(a.x, b.x, t), Math.lerp(a.y, b.y, t)) }

  /// In-place mutation for hot loops ---------------------------------

  addInto(a, b) {
    _x = a.x + b.x
    _y = a.y + b.y
    return this
  }
  subInto(a, b) {
    _x = a.x - b.x
    _y = a.y - b.y
    return this
  }
  mulIntoScalar(a, s) {
    _x = a.x * s
    _y = a.y * s
    return this
  }
  copyFrom(v) {
    _x = v.x
    _y = v.y
    return this
  }

  /// Conversion / comparison -----------------------------------------

  toList           { [_x, _y] }
  /// Raw component list, ordered (x, y). Companion to `Vec3.data` /
  /// `Vec4.data` / `Mat4.data` / `Quat.data` — used by foreign GPU
  /// upload paths that need a stable, list-shaped view of the
  /// underlying storage. Currently allocates each call (fields are
  /// scalars); cheap enough for the uses we care about.
  data             { [_x, _y] }
  approxEq(other) { approxEq(other, 0.000001) }
  approxEq(other, eps) {
    return (_x - other.x).abs < eps &&
      (_y - other.y).abs < eps
  }
  ==(other) { (other is Vec2) && _x == other.x && _y == other.y }
  !=(other) { !(this == other) }
  toString { "Vec2(%(_x), %(_y))" }
}

/// 3-component vector (`x`, `y`, `z`). Construct via
/// [Vec3.new] or factory getters (`zero` / `one` / `unitX` /
/// `unitY` / `unitZ`). Component-wise `+`, `-`, `*`, `/`;
/// dot / cross / length / normalize / lerp built in.
class Vec3 {
  construct new(x, y, z) {
    _x = x
    _y = y
    _z = z
  }

  static zero     { Vec3.new(0, 0, 0) }
  static one      { Vec3.new(1, 1, 1) }
  static unitX    { Vec3.new(1, 0, 0) }
  static unitY    { Vec3.new(0, 1, 0) }
  static unitZ    { Vec3.new(0, 0, 1) }

  x { _x }
  y { _y }
  z { _z }
  x=(v) { _x = v }
  y=(v) { _y = v }
  z=(v) { _z = v }

  +(o) { o is Vec3 ? Vec3.new(_x + o.x, _y + o.y, _z + o.z) : Vec3.new(_x + o, _y + o, _z + o) }
  -(o) { o is Vec3 ? Vec3.new(_x - o.x, _y - o.y, _z - o.z) : Vec3.new(_x - o, _y - o, _z - o) }
  *(o) { o is Vec3 ? Vec3.new(_x * o.x, _y * o.y, _z * o.z) : Vec3.new(_x * o, _y * o, _z * o) }
  /(o) { o is Vec3 ? Vec3.new(_x / o.x, _y / o.y, _z / o.z) : Vec3.new(_x / o, _y / o, _z / o) }
  - { Vec3.new(-_x, -_y, -_z) }

  lengthSq { _x * _x + _y * _y + _z * _z }
  length   { lengthSq.sqrt }

  normalized {
    var l = length
    if (l == 0) return Vec3.zero
    return Vec3.new(_x / l, _y / l, _z / l)
  }

  dot(o)        { _x * o.x + _y * o.y + _z * o.z }
  distanceSq(o) {
    var dx = _x - o.x
    var dy = _y - o.y
    var dz = _z - o.z
    return dx * dx + dy * dy + dz * dz
  }
  distance(o)   { distanceSq(o).sqrt }

  /// Right-handed cross product — `a.cross(b)` is perpendicular
  /// to both and follows the right-hand rule.
  cross(o) {
    return Vec3.new(
      _y * o.z - _z * o.y,
      _z * o.x - _x * o.z,
      _x * o.y - _y * o.x
    )
  }

  static lerp(a, b, t) {
    return Vec3.new(
      Math.lerp(a.x, b.x, t),
      Math.lerp(a.y, b.y, t),
      Math.lerp(a.z, b.z, t)
    )
  }

  /// Reflect this vector off a surface with normal `n`. Assumes
  /// `n` is already normalized.
  reflect(n) {
    var d = 2 * dot(n)
    return Vec3.new(_x - n.x * d, _y - n.y * d, _z - n.z * d)
  }

  /// In-place mutation -----------------------------------------------

  addInto(a, b) {
    _x = a.x + b.x
    _y = a.y + b.y
    _z = a.z + b.z
    return this
  }
  subInto(a, b) {
    _x = a.x - b.x
    _y = a.y - b.y
    _z = a.z - b.z
    return this
  }
  mulIntoScalar(a, s) {
    _x = a.x * s
    _y = a.y * s
    _z = a.z * s
    return this
  }
  copyFrom(v) {
    _x = v.x
    _y = v.y
    _z = v.z
    return this
  }

  toList           { [_x, _y, _z] }
  data             { [_x, _y, _z] }
  approxEq(o) { approxEq(o, 0.000001) }
  approxEq(o, eps) {
    return (_x - o.x).abs < eps &&
      (_y - o.y).abs < eps &&
      (_z - o.z).abs < eps
  }
  ==(o) { (o is Vec3) && _x == o.x && _y == o.y && _z == o.z }
  !=(o) { !(this == o) }
  toString { "Vec3(%(_x), %(_y), %(_z))" }
}

/// 4-component vector (`x`, `y`, `z`, `w`). Used primarily
/// as a homogeneous coordinate (point with `w = 1`, direction
/// with `w = 0`) and as RGBA colours. Component-wise
/// arithmetic; `dot` / `length` / `normalize` / `lerp` built
/// in.
class Vec4 {
  construct new(x, y, z, w) {
    _x = x
    _y = y
    _z = z
    _w = w
  }

  static zero     { Vec4.new(0, 0, 0, 0) }
  static one      { Vec4.new(1, 1, 1, 1) }

  /// RGBA convenience — same constructor, different mental model.
  /// Component getters return r/g/b/a aliases so colour code stays
  /// readable without forcing callers to pick a separate type.
  static rgba(r, g, b, a) { Vec4.new(r, g, b, a) }

  x { _x }
  y { _y }
  z { _z }
  w { _w }
  r { _x }
  g { _y }
  b { _z }
  a { _w }
  x=(v) { _x = v }
  y=(v) { _y = v }
  z=(v) { _z = v }
  w=(v) { _w = v }

  +(o) { o is Vec4 ? Vec4.new(_x + o.x, _y + o.y, _z + o.z, _w + o.w) : Vec4.new(_x + o, _y + o, _z + o, _w + o) }
  -(o) { o is Vec4 ? Vec4.new(_x - o.x, _y - o.y, _z - o.z, _w - o.w) : Vec4.new(_x - o, _y - o, _z - o, _w - o) }
  *(o) { o is Vec4 ? Vec4.new(_x * o.x, _y * o.y, _z * o.z, _w * o.w) : Vec4.new(_x * o, _y * o, _z * o, _w * o) }
  /(o) { o is Vec4 ? Vec4.new(_x / o.x, _y / o.y, _z / o.z, _w / o.w) : Vec4.new(_x / o, _y / o, _z / o, _w / o) }
  - { Vec4.new(-_x, -_y, -_z, -_w) }

  lengthSq { _x * _x + _y * _y + _z * _z + _w * _w }
  length   { lengthSq.sqrt }

  dot(o) { _x * o.x + _y * o.y + _z * o.z + _w * o.w }

  static lerp(a, b, t) {
    return Vec4.new(
      Math.lerp(a.x, b.x, t),
      Math.lerp(a.y, b.y, t),
      Math.lerp(a.z, b.z, t),
      Math.lerp(a.w, b.w, t)
    )
  }

  /// Drop `w` to recover a Vec3. Common when reading back the
  /// spatial portion of a homogeneous transform result.
  xyz { Vec3.new(_x, _y, _z) }

  toList           { [_x, _y, _z, _w] }
  data             { [_x, _y, _z, _w] }
  approxEq(o) { approxEq(o, 0.000001) }
  approxEq(o, eps) {
    return (_x - o.x).abs < eps &&
      (_y - o.y).abs < eps &&
      (_z - o.z).abs < eps &&
      (_w - o.w).abs < eps
  }
  ==(o) { (o is Vec4) && _x == o.x && _y == o.y && _z == o.z && _w == o.w }
  !=(o) { !(this == o) }
  toString { "Vec4(%(_x), %(_y), %(_z), %(_w))" }
}

/// 4×4 matrix in row-major storage. `at(r, c)` reads,
/// `set(r, c, v)` writes. Static factories produce the
/// common affine + projection matrices every renderer needs:
/// `Mat4.identity`, `Mat4.perspective(fovY, aspect, near, far)`,
/// `Mat4.ortho(...)`, `Mat4.lookAt(eye, target, up)`,
/// translation / rotation / scale helpers, etc.
///
/// `data` returns the underlying `List<Num>` for buffer
/// uploads; mutate the matrix through the named setters
/// rather than indexing into `data`.
class Mat4 {
  construct new() {
    _m = List.filled(16, 0)
  }

  /// Pass a flat list of 16 numbers, row-major.
  construct fromList(list) {
    if (list.count != 16) Fiber.abort("Mat4.fromList: need 16 numbers")
    _m = []
    var i = 0
    while (i < 16) {
      _m.add(list[i])
      i = i + 1
    }
  }

  static zero { Mat4.new() }

  static identity {
    var m = Mat4.new()
    m.set(0, 0, 1)
    m.set(1, 1, 1)
    m.set(2, 2, 1)
    m.set(3, 3, 1)
    return m
  }

  static translation(x, y, z) {
    var m = Mat4.identity
    m.set(0, 3, x)
    m.set(1, 3, y)
    m.set(2, 3, z)
    return m
  }

  static scale(x, y, z) {
    var m = Mat4.new()
    m.set(0, 0, x)
    m.set(1, 1, y)
    m.set(2, 2, z)
    m.set(3, 3, 1)
    return m
  }

  static rotationX(angle) {
    var c = angle.cos
    var s = angle.sin
    var m = Mat4.identity
    m.set(1, 1, c)
    m.set(1, 2, -s)
    m.set(2, 1, s)
    m.set(2, 2, c)
    return m
  }
  static rotationY(angle) {
    var c = angle.cos
    var s = angle.sin
    var m = Mat4.identity
    m.set(0, 0, c)
    m.set(0, 2, s)
    m.set(2, 0, -s)
    m.set(2, 2, c)
    return m
  }
  static rotationZ(angle) {
    var c = angle.cos
    var s = angle.sin
    var m = Mat4.identity
    m.set(0, 0, c)
    m.set(0, 1, -s)
    m.set(1, 0, s)
    m.set(1, 1, c)
    return m
  }

  /// Symmetric OpenGL-style right-handed perspective.
  /// `fovY` in radians, depth mapped to `[-1, 1]`.
  static perspective(fovY, aspect, near, far) {
    var f = 1 / (fovY / 2).tan
    var m = Mat4.new()
    m.set(0, 0, f / aspect)
    m.set(1, 1, f)
    m.set(2, 2, (far + near) / (near - far))
    m.set(2, 3, (2 * far * near) / (near - far))
    m.set(3, 2, -1)
    return m
  }

  static ortho(left, right, bottom, top, near, far) {
    var m = Mat4.new()
    m.set(0, 0, 2 / (right - left))
    m.set(1, 1, 2 / (top - bottom))
    m.set(2, 2, -2 / (far - near))
    m.set(0, 3, -(right + left) / (right - left))
    m.set(1, 3, -(top + bottom) / (top - bottom))
    m.set(2, 3, -(far + near) / (far - near))
    m.set(3, 3, 1)
    return m
  }

  /// View matrix: camera at `eye` looking at `target` with the
  /// given world-space `up`. Right-handed convention — -z points
  /// into the scene.
  static lookAt(eye, target, up) {
    var f = (target - eye).normalized      // forward
    var r = f.cross(up).normalized         // right
    var u = r.cross(f)                     // actual up
    var m = Mat4.identity
    m.set(0, 0, r.x)
    m.set(0, 1, r.y)
    m.set(0, 2, r.z)
    m.set(0, 3, -r.dot(eye))
    m.set(1, 0, u.x)
    m.set(1, 1, u.y)
    m.set(1, 2, u.z)
    m.set(1, 3, -u.dot(eye))
    m.set(2, 0, -f.x)
    m.set(2, 1, -f.y)
    m.set(2, 2, -f.z)
    m.set(2, 3, f.dot(eye))
    return m
  }

  /// Accessors -------------------------------------------------------
  at(r, c)       { _m[r * 4 + c] }
  set(r, c, v)   { _m[r * 4 + c] = v }
  toList {
    var out = []
    var i = 0
    while (i < 16) {
      out.add(_m[i])
      i = i + 1
    }
    return out
  }

  // Multiplication --------------------------------------------------

  *(o) {
    if (o is Mat4) {
      var r = Mat4.new()
      var i = 0
      while (i < 4) {
        var j = 0
        while (j < 4) {
          var s = 0
          var k = 0
          while (k < 4) {
            s = s + at(i, k) * o.at(k, j)
            k = k + 1
          }
          r.set(i, j, s)
          j = j + 1
        }
        i = i + 1
      }
      return r
    }
    // Scalar broadcast
    var r = Mat4.new()
    var i = 0
    while (i < 16) {
      r.setRaw_(i, _m[i] * o)
      i = i + 1
    }
    return r
  }

  // Internal raw setter used by the scalar multiply loop.
  setRaw_(i, v) { _m[i] = v }

  /// Raw row-major 16-element list. Returns the underlying storage
  /// by reference — foreign GPU upload paths read sequentially with
  /// List indexing instead of paying for 16 `at(r, c)` method calls
  /// per matrix. Mutating the returned list mutates the matrix.
  data { _m }

  transpose {
    var r = Mat4.new()
    var i = 0
    while (i < 4) {
      var j = 0
      while (j < 4) {
        r.set(j, i, at(i, j))
        j = j + 1
      }
      i = i + 1
    }
    return r
  }

  /// Transform a `Vec3` as a point (w=1). Homogeneous divide
  /// applied if the result's `w` isn't 1.
  transformPoint(v) {
    var x = at(0, 0) * v.x + at(0, 1) * v.y + at(0, 2) * v.z + at(0, 3)
    var y = at(1, 0) * v.x + at(1, 1) * v.y + at(1, 2) * v.z + at(1, 3)
    var z = at(2, 0) * v.x + at(2, 1) * v.y + at(2, 2) * v.z + at(2, 3)
    var w = at(3, 0) * v.x + at(3, 1) * v.y + at(3, 2) * v.z + at(3, 3)
    if (w != 0 && w != 1) {
      return Vec3.new(x / w, y / w, z / w)
    }
    return Vec3.new(x, y, z)
  }

  /// Transform a `Vec3` as a direction (w=0). Translation column
  /// has no effect — useful for normals and velocities.
  transformDir(v) {
    var x = at(0, 0) * v.x + at(0, 1) * v.y + at(0, 2) * v.z
    var y = at(1, 0) * v.x + at(1, 1) * v.y + at(1, 2) * v.z
    var z = at(2, 0) * v.x + at(2, 1) * v.y + at(2, 2) * v.z
    return Vec3.new(x, y, z)
  }

  /// Transform a full `Vec4`.
  transformVec4(v) {
    var x = at(0, 0) * v.x + at(0, 1) * v.y + at(0, 2) * v.z + at(0, 3) * v.w
    var y = at(1, 0) * v.x + at(1, 1) * v.y + at(1, 2) * v.z + at(1, 3) * v.w
    var z = at(2, 0) * v.x + at(2, 1) * v.y + at(2, 2) * v.z + at(2, 3) * v.w
    var w = at(3, 0) * v.x + at(3, 1) * v.y + at(3, 2) * v.z + at(3, 3) * v.w
    return Vec4.new(x, y, z, w)
  }

  approxEq(other)        { approxEq(other, 0.000001) }
  approxEq(other, eps) {
    var i = 0
    while (i < 16) {
      if ((_m[i] - other.toList[i]).abs >= eps) return false
      i = i + 1
    }
    return true
  }

  toString {
    var rows = []
    var r = 0
    while (r < 4) {
      rows.add("[%(at(r,0)), %(at(r,1)), %(at(r,2)), %(at(r,3))]")
      r = r + 1
    }
    return "Mat4(" + rows.join(", ") + ")"
  }
}

/// Rotation as a unit quaternion. Layout `(w, x, y, z)`;
/// identity is `(1, 0, 0, 0)`. Multiplication is
/// Hamilton-convention — `a * b` applies `b` first then `a`,
/// matching Mat4 composition order.
///
/// Constructors: [Quat.new], `Quat.identity`,
/// `Quat.fromAxisAngle(axis, angle)`,
/// `Quat.fromEulerXYZ(x, y, z)`. Common ops: `*` (compose),
/// `inverse`, `normalize`, `slerp`, `rotate(vec3)`.
class Quat {
  construct new(w, x, y, z) {
    _w = w
    _x = x
    _y = y
    _z = z
  }

  static identity { Quat.new(1, 0, 0, 0) }

  /// Rotation of `angle` (radians) around a unit-vector `axis`.
  /// Pass a non-normalised axis and the result is also non-unit.
  static fromAxisAngle(axis, angle) {
    var half = angle / 2
    var s = half.sin
    return Quat.new(half.cos, axis.x * s, axis.y * s, axis.z * s)
  }

  /// YXZ-order Euler angles (yaw, pitch, roll) in radians.
  static fromEuler(yaw, pitch, roll) {
    var cy = (yaw * 0.5).cos
    var sy = (yaw * 0.5).sin
    var cp = (pitch * 0.5).cos
    var sp = (pitch * 0.5).sin
    var cr = (roll * 0.5).cos
    var sr = (roll * 0.5).sin
    return Quat.new(
      cr * cp * cy + sr * sp * sy,
      sr * cp * cy - cr * sp * sy,
      cr * sp * cy + sr * cp * sy,
      cr * cp * sy - sr * sp * cy
    )
  }

  w { _w }
  x { _x }
  y { _y }
  z { _z }

  lengthSq { _w * _w + _x * _x + _y * _y + _z * _z }
  length   { lengthSq.sqrt }

  normalized {
    var l = length
    if (l == 0) return Quat.identity
    return Quat.new(_w / l, _x / l, _y / l, _z / l)
  }

  /// Conjugate — for a UNIT quaternion this is the inverse.
  conjugate { Quat.new(_w, -_x, -_y, -_z) }

  // Hamilton product. Non-commutative.
  *(o) {
    return Quat.new(
      _w * o.w - _x * o.x - _y * o.y - _z * o.z,
      _w * o.x + _x * o.w + _y * o.z - _z * o.y,
      _w * o.y - _x * o.z + _y * o.w + _z * o.x,
      _w * o.z + _x * o.y - _y * o.x + _z * o.w
    )
  }

  dot(o) { _w * o.w + _x * o.x + _y * o.y + _z * o.z }

  /// Spherical linear interpolation. Falls back to lerp when the
  /// two quaternions are near-parallel to avoid division blow-up.
  static slerp(a, b, t) {
    var c = a.dot(b)
    // Take the shorter arc.
    var bw = b.w
    var bx = b.x
    var by = b.y
    var bz = b.z
    if (c < 0) {
      c = -c
      bw = -bw
      bx = -bx
      by = -by
      bz = -bz
    }
    if (c > 0.9995) {
      // Near-parallel — normalize a straight lerp.
      return Quat.new(
        a.w + (bw - a.w) * t,
        a.x + (bx - a.x) * t,
        a.y + (by - a.y) * t,
        a.z + (bz - a.z) * t
      ).normalized
    }
    var theta0 = c.acos
    var theta = theta0 * t
    var sinTheta = theta.sin
    var sinTheta0 = theta0.sin
    var s1 = theta.cos - c * sinTheta / sinTheta0
    var s2 = sinTheta / sinTheta0
    return Quat.new(
      a.w * s1 + bw * s2,
      a.x * s1 + bx * s2,
      a.y * s1 + by * s2,
      a.z * s1 + bz * s2
    )
  }

  /// Rotate a `Vec3` by this quaternion (assumed unit).
  rotateVec3(v) {
    var qx = _x
    var qy = _y
    var qz = _z
    var qw = _w
    // t = 2 * cross(q.xyz, v)
    var tx = 2 * (qy * v.z - qz * v.y)
    var ty = 2 * (qz * v.x - qx * v.z)
    var tz = 2 * (qx * v.y - qy * v.x)
    // result = v + qw * t + cross(q.xyz, t)
    return Vec3.new(
      v.x + qw * tx + (qy * tz - qz * ty),
      v.y + qw * ty + (qz * tx - qx * tz),
      v.z + qw * tz + (qx * ty - qy * tx)
    )
  }

  /// Emit the equivalent 4x4 rotation matrix. Bakes the unit
  /// assumption — pass `q.normalized` first for safety.
  toMat4 {
    var xx = _x * _x
    var yy = _y * _y
    var zz = _z * _z
    var xy = _x * _y
    var xz = _x * _z
    var yz = _y * _z
    var wx = _w * _x
    var wy = _w * _y
    var wz = _w * _z
    var m = Mat4.identity
    m.set(0, 0, 1 - 2 * (yy + zz))
    m.set(0, 1, 2 * (xy - wz))
    m.set(0, 2, 2 * (xz + wy))
    m.set(1, 0, 2 * (xy + wz))
    m.set(1, 1, 1 - 2 * (xx + zz))
    m.set(1, 2, 2 * (yz - wx))
    m.set(2, 0, 2 * (xz - wy))
    m.set(2, 1, 2 * (yz + wx))
    m.set(2, 2, 1 - 2 * (xx + yy))
    return m
  }

  /// Raw component list. Order is `(w, x, y, z)` — same as the
  /// `Quat.new(w, x, y, z)` constructor — so foreign upload paths
  /// can stream the list directly into shader uniforms that store
  /// quaternions in scalar-first layout.
  data { [_w, _x, _y, _z] }

  approxEq(o) { approxEq(o, 0.000001) }
  approxEq(o, eps) {
    return (_w - o.w).abs < eps &&
      (_x - o.x).abs < eps &&
      (_y - o.y).abs < eps &&
      (_z - o.z).abs < eps
  }
  ==(o) { (o is Quat) && _w == o.w && _x == o.x && _y == o.y && _z == o.z }
  !=(o) { !(this == o) }
  toString { "Quat(%(_w), %(_x), %(_y), %(_z))" }
}
