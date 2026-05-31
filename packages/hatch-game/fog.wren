//! `@hatch:game` — Scene fog state. Cross-pipeline data shared
//! between WaterPipeline, Renderer3D and any other scene FS that
//! wants aerial perspective + a false-horizon fade. Driven by
//! `setFog(fog)` on each consumer pipeline; pipelines read its
//! fields each `beginFrame` and pack them into their own UBOs
//! (no shared GPU buffer — keeps each pipeline self-contained).
//!
//! Two fade curves are supported via `curve`:
//!   - `0` = linear, fully saturated at `end`. Cheap and
//!     predictable; ideal for hiding a finite water mesh edge
//!     because you can place `end` strictly inside the mesh
//!     boundary.
//!   - `1` = exponential-squared (`1 - exp(-(d*density)^2)`).
//!     Smooth derivative everywhere; reads as atmospheric haze.
//!
//! Bind `color` to the sky's horizon band so the world fades
//! into the visible sky band, not into an arbitrary tint:
//! `_fog.color = _sky.horizon`.

class Fog {
  /// Construct with defaults tuned for a ~150 m world (Quaternius
  /// island demo scale).
  construct new() {
    _color   = [0.96, 0.86, 0.72]   // matches the sky's warm horizon band
    _start   = 60.0                 // m — fog begins
    _end     = 130.0                // m — linear fully opaque here
    _density = 0.020                // m^-1 — for `curve = 1` exp² mode
    _curve   = 0                    // 0 linear, 1 exp²
  }

  /// Fog tint. `[r, g, b]` linear-space; usually the sky's
  /// horizon colour so the world fades into the sky.
  /// @returns {List<Num>}
  color         { _color }
  /// @param {List<Num>} v
  color=(v)     { _color = v }

  /// Distance (m) where fog begins (linear curve only).
  /// @returns {Num}
  start         { _start }
  /// @param {Num} v
  start=(v)     { _start = v }

  /// Distance (m) where fog reaches full opacity (linear curve
  /// only). Set this STRICTLY INSIDE the visible mesh edge to
  /// hide the geometry boundary against the sky.
  /// @returns {Num}
  end           { _end }
  /// @param {Num} v
  end=(v)       { _end = v }

  /// Density coefficient for `curve = 1` exponential-squared mode
  /// (m^-1). Higher = thicker.
  /// @returns {Num}
  density       { _density }
  /// @param {Num} v
  density=(v)   { _density = v }

  /// Curve mode. `0` = linear (start/end); `1` = exp² (density).
  /// @returns {Num}
  curve         { _curve }
  /// @param {Num} v
  curve=(v)     { _curve = v }
}
