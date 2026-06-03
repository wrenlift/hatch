//! procedural-world: directional sun lighting.
//!
//! Single source of truth for the warm-amber midday sun the
//! scene is lit by. Built once at `setup` and re-applied to the
//! 3D renderer at the start of every pass (main + reflection)
//! so a sliding sun would mean changing one constant here.

import "@hatch:math" for Vec3

class Sun {
  static build() {
    // Low-angle golden-hour sun. Direction steep from one side
    // (not overhead) so shadows lengthen and the water specular
    // path lights a wedge across the surface. Colour shifts from
    // warm-white toward amber so diffuse reads as sun rays, not
    // a soft-box. Ambient cooled toward sky-blue so areas in
    // shadow keep a believable bounce-light tint instead of
    // going grey.
    return {
      "dir":        Vec3.new(-0.55, -0.42, -0.72),
      "color":      Vec3.new(1.00, 0.82, 0.62),
      "intensity":  6.5,
      // Ambient is the "no shadows here either" baseline. Tuned
      // so the lit pixel's direct radiance dominates the ambient
      // floor in R and G — otherwise the shadow factor's
      // multiplicative cut leaves a lit/shadow ratio under 2×
      // and ACES squashes what's left, reading as "very faint
      // shadows". With direct ≈ (0.35, 0.29, 0.22) and ambient
      // ≈ (0.13, 0.15, 0.17), shadow gets ~3× contrast vs lit
      // while back-of-tree faces (ambient-only) still clear the
      // 0.10 luminance floor for sky readability.
      "ambient":    Vec3.new(0.55, 0.62, 0.72),
      "ambientInt": 0.60
    }
  }

  /// Push the sun + ambient into a Renderer3D before the first
  /// draw of a pass. Called twice per frame (main pass +
  /// reflection pass) so both views light identically.
  /// @param {Renderer3D} renderer
  /// @param {Map}        sun
  static applyTo(renderer, sun) {
    renderer.setAmbient(sun["ambient"], sun["ambientInt"])
    // 3-band IBL environment — subtle additive tint on top of
    // the legacy `setAmbient` fill, so back-facing surfaces pick
    // up directional bounce instead of flat grey. Values kept
    // small (~0.2 max) so we don't double-count the ambient
    // contribution and wash the scene out.
    renderer.setEnvironment(
      Vec3.new(0.16, 0.20, 0.26),    // top — cool sky hint
      Vec3.new(0.22, 0.20, 0.16),    // horizon — warm hint
      Vec3.new(0.08, 0.09, 0.06))    // ground — soft green bounce
    // Last arg = castsShadows. Renderer3D pins shadow-casting dir
    // lights to slot 0 so the PBR shader's `i == 0` shadow factor
    // path stays branch-free; only fires when the caller also
    // invoked `enableShadows(...)`.
    renderer.addDirectional(sun["dir"], sun["color"], sun["intensity"], true)
  }

  /// Bridge the same sun config into Water + Sky pipelines at
  /// setup time. WaterPipeline and SkyboxPipeline read these
  /// once each (no per-frame re-broadcast needed).
  /// @param {WaterPipeline}   water
  /// @param {SkyboxPipeline}  sky
  /// @param {Map}             sun
  static applyToScene(water, sky, sun) {
    var dir = sun["dir"]
    var col = sun["color"]
    water.setSun([dir.x, dir.y, dir.z],
                 [col.x, col.y, col.z],
                 sun["intensity"])
    water.setAmbient([0.10, 0.16, 0.22])
    sky.setSun([dir.x, dir.y, dir.z],
               [col.x, col.y, col.z],
               sun["intensity"])
  }
}
