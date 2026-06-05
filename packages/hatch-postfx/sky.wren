// `@hatch:postfx` — SkyPass. Vertical gradient sky-dome composited
// where the scene depth is at the far plane (no geometry written).
// Cel-friendly painted backdrop that completes the stylised look
// in <100 lines of shader; doesn't fight tonemap, doesn't depend
// on cubemaps or camera-relative rays.
//
// Placement in the chain matters: put it FIRST (before tonemap)
// so ACES normalises sky + scene together — keeps the gradient
// from punching out against an already-mapped backdrop. Put it
// LAST (after every other pass) when you want the painted colour
// preserved verbatim and you're confident the gradient already
// sits in display range.

import "@hatch:game" for PostPass

class SkyPass is PostPass {
  /// Build a sky pass.
  ///
  /// | Key | Type | Default | Notes |
  /// |---|---|---|---|
  /// | `zenith`  | `List` | `[0.55, 0.75, 0.92, 1.0]` | RGBA at the top of the screen. Pastel blue is the cel default. |
  /// | `horizon` | `List` | `[0.92, 0.85, 0.72, 1.0]` | RGBA at the bottom. Warmer hint for a sunset feel. |
  /// | `falloff` | `Num`  | `1.2` | Gradient exponent — `<1` softens the transition (more atmospheric), `>1` sharpens it. |
  ///
  /// @param {Map} opts
  construct new(opts) { init_(opts) }
  /// Build with defaults.
  construct new()     { init_({}) }

  init_(opts) {
    super()
    _zenith  = opts.containsKey("zenith")  ? opts["zenith"]  : [0.55, 0.75, 0.92, 1.0]
    _horizon = opts.containsKey("horizon") ? opts["horizon"] : [0.92, 0.85, 0.72, 1.0]
    _falloff = opts.containsKey("falloff") ? opts["falloff"] : 1.2
  }

  /// Diagnostic label.
  name { "sky" }

  /// `zenith` colour getter / setter — `[r, g, b, a]`.
  /// @returns {List}
  zenith       { _zenith }
  /// @param {List} v
  zenith=(v)   { _zenith = v }

  /// `horizon` colour getter / setter — `[r, g, b, a]`.
  /// @returns {List}
  horizon      { _horizon }
  /// @param {List} v
  horizon=(v)  { _horizon = v }

  /// Gradient exponent getter / setter.
  /// @returns {Num}
  falloff      { _falloff }
  /// @param {Num} v
  falloff=(v)  { _falloff = v }

  // Pass uses the standard PostFX wiring — single texture input
  // + sampler + uniform + depth. No custom layout / pipeline
  // needed beyond what `PostFX.buildFragmentPipeline_` provides.
  wantsDepth { true }

  uniformBytes { 48 }
  uniformWgsl  { "
    zenith:  vec4<f32>,
    horizon: vec4<f32>,
    falloff: f32,
    _p0:     f32,
    _p1:     f32,
    _p2:     f32,
  " }

  writeUniforms(scratch) {
    scratch[0]  = _zenith[0]
    scratch[1]  = _zenith[1]
    scratch[2]  = _zenith[2]
    scratch[3]  = _zenith.count > 3 ? _zenith[3] : 1.0
    scratch[4]  = _horizon[0]
    scratch[5]  = _horizon[1]
    scratch[6]  = _horizon[2]
    scratch[7]  = _horizon.count > 3 ? _horizon[3] : 1.0
    scratch[8]  = _falloff
    scratch[9]  = 0
    scratch[10] = 0
    scratch[11] = 0
  }

  fragmentBody { "
    let scene = textureSample(t, s, uv);
    let depth = textureSample(depthTex, s, uv);
    // Far-plane fragments only — depth ≥ 0.999 means the scene
    // clear colour is showing through. Painted gradient lands
    // there without touching geometry.
    if (depth >= 0.999) {
      // uv.y = 0 at top, 1 at bottom (PostFX vertex stage flips
      // the V axis). t = 1 at zenith, 0 at horizon.
      let g  = pow(1.0 - uv.y, u.falloff);
      let sky = mix(u.horizon.rgb, u.zenith.rgb, g);
      return vec4<f32>(sky, scene.a);
    }
    return scene;
  " }
}
