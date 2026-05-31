//! procedural-world: island heightmap + mesh + material.
//!
//! Owns the value-noise-plateau heightmap, the topographic
//! colour palette, the normal texture, the wrapping Material,
//! and the actual GPU mesh. `amp` is a mutable scalar driven by
//! the HUD `terrain amp` slider — the demo writes it each frame
//! and the per-frame model matrix scales the mesh in Y to match.
//!
//! Foliage scatter / matrix-rebuild loops are hot per-site code,
//! so the getters expose the underlying buffers (`heights / cols
//! / rows / step / size / amp`) so callers can snapshot to
//! locals for the inner loop instead of paying field-access cost
//! per cell. `heightAt(x, z)` and `slopeAt(x, z)` are convenient
//! for cold paths.

import "@hatch:game"  for Terrain
import "@hatch:gpu"   for Material, Mesh
import "@hatch:image" for Image
import "@hatch:math"  for Vec4

class Topography {
  /// Build the island from `db`'s `value-noise-plateau_height_1024.png`
  /// + `_normal_1024.png` siblings.
  /// @param {GameState} g
  /// @param {AssetDatabase} db
  construct new(g, db) {
    var heightImg = Image.decode(db.bytes("value-noise-plateau_height_1024.png"))
    var srcW = heightImg.width
    var srcH = heightImg.height
    var srcPx = heightImg.pixels

    var cols = 128
    var rows = 128
    var step = 1.2
    var ampBase = 8.0
    _cols    = cols
    _rows    = rows
    _step    = step
    _ampBase = ampBase
    _amp     = ampBase
    _size    = (cols - 1) * step

    var heights = Float32Array.new(cols * rows)
    var cx = (cols - 1) / 2
    var cz = (rows - 1) / 2
    var radius = cx
    var j = 0
    while (j < rows) {
      var sy = ((j * srcH) / rows).floor
      var dz = (j - cz) / radius
      var i = 0
      while (i < cols) {
        var sx = ((i * srcW) / cols).floor
        // Sample the red channel (grayscale → all channels equal);
        // normalise 0..255 → 0..1 then recentre to -0.5..+0.5 so
        // a midway pixel is the baseline.
        var pix = srcPx[(sy * srcW + sx) * 4]
        var raw = pix / 255 - 0.5
        // Radial smoothstep falloff so the mesh edge dips below
        // water and the ocean wraps a clean coastline silhouette.
        var dx = (i - cx) / radius
        var d2 = dx * dx + dz * dz
        var t = 1 - d2
        if (t < 0) t = 0
        if (t > 1) t = 1
        var falloff = t * t * (3 - 2 * t)
        heights[j * cols + i] = raw * falloff - 0.5 * (1 - falloff)
        i = i + 1
      }
      j = j + 1
    }
    // Two 3×3 box-filter passes — folds the sharpest value-noise
    // edges into rolling hills without losing the macro topo.
    var smoothed = Float32Array.new(cols * rows)
    var passes = 2
    var pass = 0
    while (pass < passes) {
      var sj = 0
      while (sj < rows) {
        var si = 0
        while (si < cols) {
          var sum = 0
          var count = 0
          var dj = -1
          while (dj <= 1) {
            var rj = sj + dj
            if (rj >= 0 && rj < rows) {
              var di = -1
              while (di <= 1) {
                var ri = si + di
                if (ri >= 0 && ri < cols) {
                  sum = sum + heights[rj * cols + ri]
                  count = count + 1
                }
                di = di + 1
              }
            }
            dj = dj + 1
          }
          smoothed[sj * cols + si] = sum / count
          si = si + 1
        }
        sj = sj + 1
      }
      var ci = 0
      while (ci < cols * rows) {
        heights[ci] = smoothed[ci]
        ci = ci + 1
      }
      pass = pass + 1
    }
    _heights = heights
    _mesh = Terrain.meshFromHeightmap(g.device, heights, cols, rows, {
      "stepX":     step,
      "stepZ":     step,
      "amplitude": ampBase
    })

    // Topographic colour bands. Sand at the shore, bright grass
    // on plains, darker forest at altitude, rocky tops. cols×rows
    // texture indexed 1:1 by mesh UV; the plateau normal map adds
    // micro-relief on top.
    var topoBytes = ByteArray.new(cols * rows * 4)
    var k = 0
    var jj = 0
    while (jj < rows) {
      var ii = 0
      while (ii < cols) {
        var hRaw = heights[jj * cols + ii]
        var y = hRaw * ampBase
        var r = 0
        var gC = 0
        var b = 0
        if (y < -2.5) {
          // Submerged sea floor — dim wet-sand. The water alpha
          // blend tints it blue at depth so a near-neutral brown
          // reads correctly through the body.
          r = 140
          gC = 128
          b = 96
        } else if (y < 0.3) {
          // Wet sand / beach shoreline.
          r = 224
          gC = 206
          b = 142
        } else if (y < 1.6) {
          // Plain land — bright brown+green (soil with grass).
          r = 168
          gC = 170
          b = 80
        } else if (y < 3.5) {
          // Plateau forest — saturated green.
          r = 78
          gC = 140
          b = 56
        } else if (y < 5.0) {
          // Rocky transition — light grey, sparse vegetation.
          r = 140
          gC = 132
          b = 120
        } else {
          // Hill / mountain rock — dark grey.
          r = 92
          gC = 86
          b = 80
        }
        topoBytes[k]     = r
        topoBytes[k + 1] = gC
        topoBytes[k + 2] = b
        topoBytes[k + 3] = 255
        k = k + 4
        ii = ii + 1
      }
      jj = jj + 1
    }
    var topoTex = g.device.createTexture({
      "width":  cols, "height": rows,
      "format": "rgba8unorm-srgb",
      "usage":  ["texture-binding", "copy-dst"],
      "label":  "terrain-topo-palette"
    })
    g.device.writeTexture(topoTex, topoBytes, {
      "width":       cols,
      "height":      rows,
      "bytesPerRow": cols * 4
    })
    var normalImg = Image.decode(db.bytes("value-noise-plateau_normal_1024.png"))
    var normalTex = g.device.uploadImage(normalImg, {
      "format": "rgba8unorm",
      "label":  "terrain-normal"
    })
    _mat = Material.new(Vec4.new(1.0, 1.0, 1.0, 1.0))
    _mat.albedoTexture    = topoTex
    _mat.normalTexture    = normalTex
    _mat.roughnessFactor  = 0.85
    _mat.metallicFactor   = 0.0
  }

  // Resource handles
  mesh    { _mesh }
  mat     { _mat }

  // Geometry
  cols    { _cols }
  rows    { _rows }
  step    { _step }
  size    { _size }
  heights { _heights }

  // Mutable Y-scale; demo writes from HUD slider each frame.
  ampBase { _ampBase }
  amp     { _amp }
  amp=(v) { _amp = v }

  /// Bilinearly sample world-space Y at world (x, z). Matches
  /// what the mesh rasterizer interpolates between vertex
  /// heights — keeping foliage on the visible surface as the amp
  /// slider scales the terrain.
  /// @param {Num} x. World metres.
  /// @param {Num} z. World metres.
  /// @returns {Num} World Y in metres at (x, z).
  heightAt(x, z) {
    var half = _size / 2
    var fx = (x + half) / _step
    var fz = (z + half) / _step
    var i0 = fx.floor
    var j0 = fz.floor
    var tx = fx - i0
    var tz = fz - j0
    if (i0 < 0) {
      i0 = 0
      tx = 0
    }
    if (i0 >= _cols - 1) {
      i0 = _cols - 2
      tx = 1
    }
    if (j0 < 0) {
      j0 = 0
      tz = 0
    }
    if (j0 >= _rows - 1) {
      j0 = _rows - 2
      tz = 1
    }
    var h00 = _heights[j0 * _cols + i0]
    var h10 = _heights[j0 * _cols + i0 + 1]
    var h01 = _heights[(j0 + 1) * _cols + i0]
    var h11 = _heights[(j0 + 1) * _cols + i0 + 1]
    var h0  = h00 + (h10 - h00) * tx
    var h1  = h01 + (h11 - h01) * tx
    return (h0 + (h1 - h0) * tz) * _amp
  }

  /// Gradient magnitude at (x, z) — high on cliffs, near-zero on
  /// plains. Foliage placement uses this to keep dense scatter
  /// off the plateau-edge cliff faces.
  /// @param {Num} x. World metres.
  /// @param {Num} z. World metres.
  /// @returns {Num}
  slopeAt(x, z) {
    var s = _step
    var h  = heightAt(x, z)
    var hx = heightAt(x + s, z)
    var hz = heightAt(x, z + s)
    var dx = hx - h
    var dz = hz - h
    return (dx * dx + dz * dz).sqrt
  }
}
