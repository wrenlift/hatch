//! procedural-world: live-mutable HUD knobs.
//!
//! Every panel slider mutates a `{"v": Num}` Map (or `{flag: Bool}`
//! for toggles) in place; readers in `draw()` pick up the latest
//! value with no setter chains. Centralising the construction
//! here means a stale default in one place (e.g. `fov.v = 55.0`)
//! can be tuned without grepping for the ref's allocation site
//! in 1200+ lines of `setup`.
//!
//! Naming: each top-level key is a slider's identity. The value
//! is the Map the panel binds to. Concerns read e.g.
//! `_knobs["fogStart"]["v"]` per frame.

class Knobs {
  static make() {
    return {
      // Camera + atmosphere
      "fov":         { "v": 55.0 },
      "fogStart":    { "v": 60.0 },
      "fogEnd":      { "v": 130.0 },
      "fogDensity":  { "v": 0.020 },
      "cloudCover":  { "v": 0.42 },
      "fogFlags":    { "expCurve": false },
      // Rain weather. `intensity` is particles per second (0
      // disables the emitter); `fallSpeed` is metres/sec
      // downward.
      "rainOn":      { "v": false },
      "rainRate":    { "v": 500.0 },
      "rainSpeed":   { "v": 14.0 },

      // Water surface
      "waterAlpha":  { "v": 0.91 },
      "foamThresh":  { "v": 1.0 },
      "flowStr":     { "v": 0.0 },
      "shoreBand":   { "v": 0.4 },
      "waterY":      { "v": -1.5 },

      // Terrain + foliage density
      "terrainAmp":  { "v": 8.0 },
      "scatter":     { "v": 0.07 },
      "grassDens":   { "v": 0.95 },
      "otherDens":   { "v": 0.60 },

      // Scene flags (toggles)
      "flags":       {
        "showFoliage": true,
        "pauseWater":  false,
        "reflection":  false
      }
    }
  }
}
