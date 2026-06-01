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
      "intensity":  4.5,
      // Ambient is the "no shadows here either" baseline — set
      // too high and shadowed regions read as lit, washing the
      // direct sunlight contrast out. The previous 0.55/0.62/0.74
      // × 0.95 = ~0.55 brightness meant a fully shadowed pixel
      // still received >50% of the lit pixel's light, making the
      // shadow factor visually disappear. Cool sky-tinted ambient
      // at ~30% strength leaves shadow regions readable but
      // distinctly darker than direct sun.
      "ambient":    Vec3.new(0.42, 0.50, 0.62),
      "ambientInt": 0.55
    }
  }

  /// Push the sun + ambient into a Renderer3D before the first
  /// draw of a pass. Called twice per frame (main pass +
  /// reflection pass) so both views light identically.
  /// @param {Renderer3D} renderer
  /// @param {Map}        sun
  static applyTo(renderer, sun) {
    renderer.setAmbient(sun["ambient"], sun["ambientInt"])
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
