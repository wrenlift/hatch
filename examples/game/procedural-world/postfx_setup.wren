//! procedural-world: post-process chain configuration.
//!
//! One-shot setter — attaches a PostFX chain to `g.postFX` with
//! ACES Tonemap + soft Vignette. Exposure / vignette params are
//! tuned for the saturated Quaternius palette + teal-water look;
//! callers can swap the chain entirely by skipping this and
//! building their own.

import "@hatch:game"   for PostFX
import "@hatch:postfx" for Tonemap, Vignette

class PostFxSetup {
  /// Attach the standard chain (Tonemap → Vignette) to `g.postFX`.
  /// @param {GameState} g
  static apply(g) {
    g.postFX = PostFX.new(g)
    g.postFX.add(Tonemap.new({ "exposure": 1.15 }))
    g.postFX.add(Vignette.new({
      "strength": 0.28,
      "radius":   0.70,
      "softness": 0.45
    }))
  }
}
