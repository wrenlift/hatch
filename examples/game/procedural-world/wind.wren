//! procedural-world: wind state. A single Map driven by the
//! `wind base` and `wind gust` HUD sliders, consumed by water
//! (chop direction + amp gust modulation) and Renderer3D
//! (foliage sway vector).

class Wind {
  static make() {
    return {
      "baseX":        1,
      "baseY":        0,
      "baseZ":        0,
      "baseStrength": 1.0,
      "gust":         0.09,
      "scale":        0.04,
      "timeScale":    0.3,
      "seed":         7
    }
  }
}
