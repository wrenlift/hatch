//! `@hatch:postfx` — common post-processing effects for the
//! WrenLift game framework. Each effect is a `PostPass` subclass
//! that drops into the chain primitive `@hatch:game` provides:
//!
//! ```wren
//! import "@hatch:game"   for Game, PostFX
//! import "@hatch:postfx" for Tonemap, Vignette, FXAA, ColorGrade
//!
//! class Demo is Game {
//!   construct new() {}
//!   setup(g) {
//!     g.postFX = PostFX.new(g)
//!     g.postFX.add(FXAA.new())
//!     g.postFX.add(ColorGrade.new({ "gain": [1.05, 1.0, 0.95] }))
//!     g.postFX.add(Tonemap.new({ "exposure": 1.2 }))
//!     g.postFX.add(Vignette.new({ "strength": 0.4 }))
//!   }
//! }
//! ```
//!
//! Order matters — passes run top-to-bottom, each reading the
//! previous output. A typical pipeline is **AA → grade →
//! tonemap → vignette / chromatic-aberration**: AA fixes
//! geometry, grading and tonemapping bring HDR-ish input into
//! display range, and the final cosmetic effects shape the look.
//!
//! Every effect ships with sensible defaults; pass an empty
//! `{}` to opt into the look without tuning.

import "@hatch:game" for PostPass

// Bloom lives in its own file because it builds its own
// pipelines + bind-group layouts (additive-blended upsample,
// two-texture composite) — the single-pass `fragmentBody`
// shape would be cramped trying to host all four sub-shaders.
import "./bloom"   for Bloom
import "./outline" for OutlinePass
import "./sky"     for SkyPass

// Shared helper for Map-or-default float / list config.
class Cfg_ {
  static numOr(opts, key, fallback) {
    if (opts == null || !opts.containsKey(key)) return fallback
    var v = opts[key]
    if (!(v is Num)) Fiber.abort("@hatch:postfx: '%(key)' must be a Num, got %(v.type)")
    return v
  }
  static vec3Or(opts, key, fallback) {
    if (opts == null || !opts.containsKey(key)) return fallback
    var v = opts[key]
    if (!(v is List) || v.count < 3) {
      Fiber.abort("@hatch:postfx: '%(key)' must be a 3-element List, got %(v.type)")
    }
    return [v[0], v[1], v[2]]
  }
}

/// Approximate-ACES tonemap. Maps potentially out-of-range linear
/// colour into `0..1` with a film-like shoulder curve, gated by
/// an exposure multiplier. Useful as the *final* colour-mapping
/// step in any chain that runs HDR-ish accumulation (additive
/// particles, glowy materials, bright skies).
class Tonemap is PostPass {
  /// Build a tonemap pass.
  ///
  /// | Key | Type | Default | Notes |
  /// |---|---|---|---|
  /// | `exposure` | `Num` | `1.0` | Linear pre-multiplier; `>1` brightens, `<1` darkens. |
  ///
  /// @param {Map} opts
  construct new(opts) {
    super()
    _exposure = Cfg_.numOr(opts, "exposure", 1.0)
  }

  /// Build with defaults.
  construct new() {
    super()
    _exposure = 1.0
  }

  /// @returns {Num}
  exposure       { _exposure }
  /// @param {Num} v
  exposure=(v)   { _exposure = v }

  name { "tonemap" }
  uniformBytes { 16 }
  uniformWgsl  { "exposure: f32, _p0: f32, _p1: f32, _p2: f32" }

  writeUniforms(scratch) {
    scratch[0] = _exposure
    scratch[1] = 0
    scratch[2] = 0
    scratch[3] = 0
  }

  fragmentBody { "
    let sample = textureSample(t, s, uv).rgb * u.exposure;
    // Narkowicz approximate ACES — adequate for game-scale HDR
    // without the full curve's matrix ops.
    let a = 2.51;
    let b = 0.03;
    let c = 2.43;
    let d = 0.59;
    let e = 0.14;
    let mapped = clamp(
      (sample * (a * sample + b)) / (sample * (c * sample + d) + e),
      vec3<f32>(0.0), vec3<f32>(1.0)
    );
    return vec4<f32>(mapped, 1.0);
  " }
}

/// Radial vignette. Darkens the frame from the centre outward
/// with a smoothstep falloff. Subtle (`strength` ~0.3) for a
/// cinematic feel; heavier (`strength` ~0.7+) for horror /
/// scope-hood looks.
class Vignette is PostPass {
  /// Build a vignette.
  ///
  /// | Key | Type | Default | Notes |
  /// |---|---|---|---|
  /// | `strength` | `Num` | `0.4` | `0` = no effect, `1` = fully black at corners. |
  /// | `radius`   | `Num` | `0.75`| Where the falloff begins (0=centre, 1=corner). |
  /// | `softness` | `Num` | `0.45`| Width of the transition band. |
  ///
  /// @param {Map} opts
  construct new(opts) {
    super()
    _strength = Cfg_.numOr(opts, "strength", 0.4)
    _radius   = Cfg_.numOr(opts, "radius",   0.75)
    _softness = Cfg_.numOr(opts, "softness", 0.45)
  }

  /// Build with defaults.
  construct new() {
    super()
    _strength = 0.4
    _radius   = 0.75
    _softness = 0.45
  }

  /// @returns {Num}
  strength       { _strength }
  /// @param {Num} v
  strength=(v)   { _strength = v }
  /// @returns {Num}
  radius         { _radius }
  /// @param {Num} v
  radius=(v)     { _radius = v }
  /// @returns {Num}
  softness       { _softness }
  /// @param {Num} v
  softness=(v)   { _softness = v }

  name { "vignette" }
  uniformBytes { 16 }
  uniformWgsl  { "strength: f32, radius: f32, softness: f32, _p0: f32" }

  writeUniforms(scratch) {
    scratch[0] = _strength
    scratch[1] = _radius
    scratch[2] = _softness
    scratch[3] = 0
  }

  fragmentBody { "
    let centred = uv - vec2<f32>(0.5, 0.5);
    let dist    = length(centred) * 1.41421356;
    let mask    = smoothstep(u.radius, u.radius + u.softness, dist);
    let colour  = textureSample(t, s, uv);
    let dim     = colour.rgb * (1.0 - mask * u.strength);
    return vec4<f32>(dim, colour.a);
  " }
}

/// Luma-driven approximate FXAA. Detects local edges via the
/// luma gradient and blends along them to soften aliasing. Single
/// fullscreen pass — much cheaper than MSAA, fine for stylised /
/// low-poly content; misses sub-pixel detail compared to TAA.
///
/// Run *first* in the chain (before tonemap / grading) so the
/// luma analysis works on input-range colours.
class FXAA is PostPass {
  /// Build an FXAA pass.
  ///
  /// | Key | Type | Default | Notes |
  /// |---|---|---|---|
  /// | `subpixel` | `Num` | `0.75` | Amount of sub-pixel smoothing. `0`=off, `1`=heavy. |
  /// | `edgeThreshold` | `Num` | `0.166` | Minimum local contrast to treat as an edge. |
  /// | `edgeThresholdMin` | `Num` | `0.0312` | Floor below which detection bails (cuts shimmer in dark areas). |
  ///
  /// @param {Map} opts
  construct new(opts) {
    super()
    _subpixel        = Cfg_.numOr(opts, "subpixel",          0.75)
    _edgeThreshold   = Cfg_.numOr(opts, "edgeThreshold",     0.166)
    _edgeThresholdMin = Cfg_.numOr(opts, "edgeThresholdMin", 0.0312)
  }

  /// Build with defaults.
  construct new() {
    super()
    _subpixel        = 0.75
    _edgeThreshold   = 0.166
    _edgeThresholdMin = 0.0312
  }

  /// @returns {Num}
  subpixel          { _subpixel }
  /// @param {Num} v
  subpixel=(v)      { _subpixel = v }
  /// @returns {Num}
  edgeThreshold     { _edgeThreshold }
  /// @param {Num} v
  edgeThreshold=(v) { _edgeThreshold = v }
  /// @returns {Num}
  edgeThresholdMin  { _edgeThresholdMin }
  /// @param {Num} v
  edgeThresholdMin=(v) { _edgeThresholdMin = v }

  name { "fxaa" }
  uniformBytes { 16 }
  uniformWgsl  { "subpixel: f32, edgeThreshold: f32, edgeThresholdMin: f32, _p0: f32" }

  writeUniforms(scratch) {
    scratch[0] = _subpixel
    scratch[1] = _edgeThreshold
    scratch[2] = _edgeThresholdMin
    scratch[3] = 0
  }

  fragmentBody { "
    let dims     = vec2<f32>(textureDimensions(t));
    let texel    = vec2<f32>(1.0, 1.0) / dims;

    // Sample the four cardinal neighbours + the centre.
    let centre   = textureSample(t, s, uv);
    let north    = textureSample(t, s, uv + vec2<f32>( 0.0, -texel.y)).rgb;
    let south    = textureSample(t, s, uv + vec2<f32>( 0.0,  texel.y)).rgb;
    let east     = textureSample(t, s, uv + vec2<f32>( texel.x,  0.0)).rgb;
    let west     = textureSample(t, s, uv + vec2<f32>(-texel.x,  0.0)).rgb;

    // Rec.709 luma.
    let lumaCoef = vec3<f32>(0.299, 0.587, 0.114);
    let lc       = dot(centre.rgb, lumaCoef);
    let ln       = dot(north,      lumaCoef);
    let ls       = dot(south,      lumaCoef);
    let le       = dot(east,       lumaCoef);
    let lw       = dot(west,       lumaCoef);

    let lmin     = min(lc, min(min(ln, ls), min(le, lw)));
    let lmax     = max(lc, max(max(ln, ls), max(le, lw)));
    let lrange   = lmax - lmin;

    // No edge here → return original sample.
    if (lrange < max(u.edgeThresholdMin, lmax * u.edgeThreshold)) {
      return centre;
    }

    // Sample diagonals to estimate edge direction.
    let nw       = textureSample(t, s, uv + vec2<f32>(-texel.x, -texel.y)).rgb;
    let ne       = textureSample(t, s, uv + vec2<f32>( texel.x, -texel.y)).rgb;
    let sw       = textureSample(t, s, uv + vec2<f32>(-texel.x,  texel.y)).rgb;
    let se       = textureSample(t, s, uv + vec2<f32>( texel.x,  texel.y)).rgb;

    let blendN   = (north + south + east + west) * 0.25;
    let blendD   = (nw + ne + sw + se) * 0.25;
    let blend    = mix(blendN, blendD, 0.5);
    return vec4<f32>(mix(centre.rgb, blend, u.subpixel), centre.a);
  " }
}

/// Three-band colour grading: lift (shadows), gamma (mids), gain
/// (highlights). Standard cinematic grading control surface. Each
/// is a per-channel `vec3<f32>` so you can warm shadows + cool
/// highlights / etc.
class ColorGrade is PostPass {
  /// Build a colour-grade pass.
  ///
  /// | Key | Type | Default | Notes |
  /// |---|---|---|---|
  /// | `lift`  | `[r,g,b]` | `[0, 0, 0]` | Added to shadows; `>0` warms, `<0` cools. |
  /// | `gamma` | `[r,g,b]` | `[1, 1, 1]` | Power applied to mids. |
  /// | `gain`  | `[r,g,b]` | `[1, 1, 1]` | Multiplier on highlights. |
  /// | `saturation` | `Num` | `1.0` | `0` = greyscale, `1` = unchanged, `>1` boosts. |
  ///
  /// @param {Map} opts
  construct new(opts) {
    super()
    _lift       = Cfg_.vec3Or(opts, "lift",  [0, 0, 0])
    _gamma      = Cfg_.vec3Or(opts, "gamma", [1, 1, 1])
    _gain       = Cfg_.vec3Or(opts, "gain",  [1, 1, 1])
    _saturation = Cfg_.numOr( opts, "saturation", 1.0)
  }

  /// Build with defaults.
  construct new() {
    super()
    _lift       = [0, 0, 0]
    _gamma      = [1, 1, 1]
    _gain       = [1, 1, 1]
    _saturation = 1.0
  }

  /// @returns {List<Num>}
  lift            { _lift }
  /// @param {List<Num>} v
  lift=(v)        { _lift = [v[0], v[1], v[2]] }
  /// @returns {List<Num>}
  gamma           { _gamma }
  /// @param {List<Num>} v
  gamma=(v)       { _gamma = [v[0], v[1], v[2]] }
  /// @returns {List<Num>}
  gain            { _gain }
  /// @param {List<Num>} v
  gain=(v)        { _gain = [v[0], v[1], v[2]] }
  /// @returns {Num}
  saturation      { _saturation }
  /// @param {Num} v
  saturation=(v)  { _saturation = v }

  name { "colorgrade" }
  // 3 vec4 chunks: lift / gamma / gain (each padded to vec4) plus
  // saturation scalar.
  uniformBytes { 64 }
  uniformWgsl  {
    "lift: vec4<f32>, gamma: vec4<f32>, gain: vec4<f32>, saturation: vec4<f32>"
  }

  writeUniforms(scratch) {
    scratch[0]  = _lift[0]
    scratch[1]  = _lift[1]
    scratch[2]  = _lift[2]
    scratch[3]  = 0
    scratch[4]  = _gamma[0]
    scratch[5]  = _gamma[1]
    scratch[6]  = _gamma[2]
    scratch[7]  = 0
    scratch[8]  = _gain[0]
    scratch[9]  = _gain[1]
    scratch[10] = _gain[2]
    scratch[11] = 0
    scratch[12] = _saturation
    scratch[13] = 0
    scratch[14] = 0
    scratch[15] = 0
  }

  fragmentBody { "
    var c = textureSample(t, s, uv);
    // Lift / gamma / gain — order matters: lift first (shifts
    // black point), then gamma (re-centres mids), then gain
    // (scales highlights).
    c = vec4<f32>(c.rgb + u.lift.rgb, c.a);
    c = vec4<f32>(pow(max(c.rgb, vec3<f32>(0.0)), vec3<f32>(1.0) / max(u.gamma.rgb, vec3<f32>(0.001))), c.a);
    c = vec4<f32>(c.rgb * u.gain.rgb, c.a);
    // Rec.709 luma-preserving saturation.
    let lumaCoef = vec3<f32>(0.299, 0.587, 0.114);
    let grey     = vec3<f32>(dot(c.rgb, lumaCoef));
    c = vec4<f32>(mix(grey, c.rgb, u.saturation.x), c.a);
    return c;
  " }
}

/// Per-channel radial offset (chromatic aberration). The red and
/// blue channels sample at different radial offsets from the
/// centre, producing a colour-fringed look — subtle for "lens
/// imperfection" realism, heavy for psychedelic / impact-frame
/// effects.
class ChromaticAberration is PostPass {
  /// Build a chromatic-aberration pass.
  ///
  /// | Key | Type | Default | Notes |
  /// |---|---|---|---|
  /// | `strength` | `Num` | `0.003` | Maximum per-channel offset (in uv space). |
  /// | `falloff`  | `Num` | `2.0`   | Exponent — larger = effect concentrated at the corners. |
  ///
  /// @param {Map} opts
  construct new(opts) {
    super()
    _strength = Cfg_.numOr(opts, "strength", 0.003)
    _falloff  = Cfg_.numOr(opts, "falloff",  2.0)
  }

  /// Build with defaults.
  construct new() {
    super()
    _strength = 0.003
    _falloff  = 2.0
  }

  /// @returns {Num}
  strength       { _strength }
  /// @param {Num} v
  strength=(v)   { _strength = v }
  /// @returns {Num}
  falloff        { _falloff }
  /// @param {Num} v
  falloff=(v)    { _falloff = v }

  name { "chromatic-aberration" }
  uniformBytes { 16 }
  uniformWgsl  { "strength: f32, falloff: f32, _p0: f32, _p1: f32" }

  writeUniforms(scratch) {
    scratch[0] = _strength
    scratch[1] = _falloff
    scratch[2] = 0
    scratch[3] = 0
  }

  fragmentBody { "
    let centred  = uv - vec2<f32>(0.5, 0.5);
    let distance = length(centred);
    let dir      = select(vec2<f32>(0.0), centred / distance, distance > 0.0001);
    let amt      = u.strength * pow(distance * 1.41421356, u.falloff);
    let r        = textureSample(t, s, uv + dir * amt).r;
    let g        = textureSample(t, s, uv).g;
    let b        = textureSample(t, s, uv - dir * amt).b;
    let a        = textureSample(t, s, uv).a;
    return vec4<f32>(r, g, b, a);
  " }
}
