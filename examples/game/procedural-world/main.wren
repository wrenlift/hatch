// Procedural-world integration demo.
//
// Composes every shipped phase from the procedural-world parity
// plan into one running scene with live HUD controls:
//
//   Noise.fillSimplex2 + Terrain.fromNoise   →  ground mesh
//   Foliage.scatter + Noise threshold        →  density-modulated
//                                              cube placements
//   ClusterGrid                              →  spatial lookup
//   Camera3D.frustumPlanes + Frustum         →  per-frame cull
//   Lod.select3                              →  close/mid/far
//   Renderer3D.drawMeshInstanced             →  one drawIndexed
//                                              per LOD bucket
//   WaterPipeline                            →  animated lake
//   Wind                                     →  passive force
//                                              feeding the HUD
//   HUDPanel                                 →  every knob live
//
// Camera orbits around the world centre via mouse drag; scroll
// wheel zooms. Controls live in a top-left panel.

import "@hatch:game"    for Game,
                            Terrain, Foliage, Wind,
                            Water, WaterPipeline,
                            PostFX
import "@hatch:postfx"  for Tonemap, Vignette, ColorGrade
import "@hatch:gpu"     for Gpu, Renderer3D, Renderer2D,
                            Camera3D, Camera2D,
                            Frustum, Lod, Mesh, Material
import "@hatch:hud"     for HUD, HUDPanel
import "@hatch:spatial" for ClusterGrid
import "@hatch:math"    for Vec3, Vec4, Mat4
import "@hatch:noise"   for Noise
import "@hatch:assets"  for Assets
import "@hatch:image"   for Image
import "@hatch:fs"      for Fs
import "@hatch:gltf"    for Gltf

// Thin wrappers so HUD widgets see mouse coords in the same
// design-space the Camera2D.contain projection draws against.
// Without these, the panel renders at design coords (1280×720)
// but its slider / button hit tests read raw surface pixels and
// land at the wrong scale — clicks miss the widget under the
// cursor and the orbit gate fires through.
class ScaledInput_ {
  construct new(real, sx, sy) {
    _real = real
    _sx   = sx
    _sy   = sy
  }
  mouseX { _real.mouseX * _sx }
  mouseY { _real.mouseY * _sy }
  mouseDown(b)         { _real.mouseDown(b) }
  mouseJustPressed(b)  { _real.mouseJustPressed(b) }
  mouseJustReleased(b) { _real.mouseJustReleased(b) }
}

class ScaledGame_ {
  construct new(real, sx, sy) {
    _real  = real
    _input = ScaledInput_.new(real.input, sx, sy)
  }
  input  { _input }
  device { _real.device }
  width  { _real.width }
  height { _real.height }
}

class ProceduralWorld is Game {
  construct new() {}

  config { {
    "title":      "Procedural World",
    // Smaller than the typical 1280×720 — at the new LogicalSize
    // scaling that would fill most of a 13" laptop and read as
    // fullscreen. 960×600 leaves room for a desktop background.
    "width":      960,
    "height":     600,
    "clearColor": [0.45, 0.62, 0.78, 1.0],   // sky blue
    "depth":      true
  } }

  setup(g) {
    _device = g.device

    // ── Renderers ───────────────────────────────────────────────
    _renderer = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)
    _water    = WaterPipeline.new(g.device, g.surfaceFormat, g.depthFormat)

    // ── Post-process chain ──────────────────────────────────────
    // BLOCKED: wlift's class-field codegen mis-routes references
    // inside `PostPass` subclasses, so the cached pipeline / layout
    // / bindgroup handles end up pointing at the wrong slots.
    // First it manifested as `_pipelines is Num`, then after a
    // defensive re-init as `BindGroup.create: unknown layout id`.
    // The chain orchestration needs a wlift-level fix for the
    // inheritance + private-field interaction before we can wire
    // ACES tonemap / vignette / bloom here. Kept the imports + this
    // comment so re-enabling is a one-line change once the bug is
    // resolved upstream.
    //
    // g.postFX = PostFX.new(g)
    // g.postFX.add(Tonemap.new({ "exposure": 1.15 }))
    // g.postFX.add(Vignette.new({ "strength": 0.28 }))

    // Low-angle golden-hour sun. Direction is steep from one side
    // rather than overhead, so shadows lengthen and the specular
    // path on water lights up a wedge across the surface (the
    // classic ocean-sun glitter). Colour shifts from warm-white to
    // a saturated amber so the diffuse term reads as sun rays,
    // not a soft-box. Ambient is cooled to sky-blue so areas in
    // shadow keep a believable bounce-light tint instead of going
    // grey.
    _sunDir       = Vec3.new(-0.55, -0.42, -0.72)
    _sunColor     = Vec3.new(1.00, 0.78, 0.55)
    _sunIntensity = 3.2
    _ambient      = Vec3.new(0.55, 0.62, 0.74)
    _ambientInt   = 0.95
    _water.setSun([_sunDir.x, _sunDir.y, _sunDir.z],
                  [_sunColor.x, _sunColor.y, _sunColor.z],
                  _sunIntensity)
    // Water ambient picks up the cooler sky tint so the body
    // colour doesn't read as flat black where the sun isn't.
    _water.setAmbient([0.10, 0.16, 0.22])
    // Shore foam — sample the scene depth so foam fades in along
    // the coastline. Near/far must match the camera's perspective
    // params below; bandMeters is how deep the terrain can be
    // beneath the water surface before foam fully fades.
    _shoreBandRef = { "v": 0.4 }
    _water.setShore(g.depthView, 0.5, 600, _shoreBandRef["v"])
    // Allocate the planar-reflection target sized to the surface.
    _water.resize(g.width, g.height)

    // ── Camera (orbit) ──────────────────────────────────────────
    _yaw      = 0.6
    _pitch    = 0.55
    _distance = 90
    _target   = Vec3.new(0, 0, 0)
    _fovY     = 55
    // Mirror camera reused every frame for the planar-reflection
    // pass. Allocated once; eye/target/up are reset per frame.
    _mirrorCamera = Camera3D.perspective(_fovY, 1.0, 0.5, 600)
    var aspect = g.width / g.height
    _camera = Camera3D.perspective(_fovY, aspect, 0.5, 600)
    rebuildCameraView_()

    _drag = false
    _moved = false

    // ── Live state. Every Map below feeds a HUDPanel row; the
    //    panel mutates them in place and we read them each frame.
    // Wave amplitude is in world units and is compared directly
    // against the terrain's nearshore relief — keep it small so
    // peaks stay below the sand band. Higher frequency reads as
    // chop instead of ocean swell.
    _waveOpts = {
      "amplitude": 0.18,
      "scale":     0.45,
      "timeScale": 0.7
    }
    // Translucency, crest foam threshold, and flow direction live
    // here so the HUD sliders mutate them in place each frame.
    _waterAlphaRef  = { "v": 0.91 }
    _foamThreshRef  = { "v": 1.0 }
    _flowStrengthRef = { "v": 0.0 }
    _windOpts = {
      "baseX":        1,
      "baseY":        0,
      "baseZ":        0,
      "baseStrength": 1.0,
      "gust":         0.09,
      "scale":        0.04,
      "timeScale":    0.3,
      "seed":         7
    }
    _flags = {
      "showFoliage": true,
      "pauseWater":  false,
      "reflection":  false
    }
    _seed = 1337

    // ── Terrain (sampled from value-noise-plateau PNG) ──────────
    // The plateau noise carries the topography we want: flat
    // tops, sharp edges, internal depressions inside plateaus
    // (those darker pits show up as inland ponds once we render
    // water at a level above them). Radial falloff still applies
    // so the bundle's edges drop below water level and the
    // ocean wraps a coherent island silhouette.
    // Try the local `assets` dir first; fall back to the workspace
    // path if `hatch run` was launched from somewhere else (the
    // typical case is `target/release/hatch run hatch/examples/.../
    // procedural-world.hatch` from the wren_lift root, where cwd
    // is wren_lift and the demo's assets sit two levels deeper).
    var candidates = [
      "assets",
      "hatch/examples/game/procedural-world/assets",
      "examples/game/procedural-world/assets"
    ]
    var assetsPath = null
    for (p in candidates) {
      if (Fs.isDir(p)) {
        assetsPath = p
        break
      }
    }
    if (assetsPath == null) {
      Fiber.abort("procedural-world: could not locate the `assets` dir. Run from the demo's package directory.")
    }
    var heightDb = Assets.open(assetsPath)
    var heightImg = Image.decode(heightDb.bytes("value-noise-plateau_height_1024.png"))
    var srcW = heightImg.width
    var srcH = heightImg.height
    var srcPx = heightImg.pixels

    var terrainW = 128
    var terrainD = 128
    var terrainStep = 1.2
    var terrainAmp  = 8.0
    _terrainSize = (terrainW - 1) * terrainStep
    _terrainAmp  = terrainAmp
    _terrainStep = terrainStep

    var heights = Float32Array.new(terrainW * terrainD)
    var cx = (terrainW - 1) / 2
    var cz = (terrainD - 1) / 2
    var radius = cx
    var j = 0
    while (j < terrainD) {
      var sy = ((j * srcH) / terrainD).floor
      var dz = (j - cz) / radius
      var i = 0
      while (i < terrainW) {
        var sx = ((i * srcW) / terrainW).floor
        // Sample the red channel (textures are grayscale so RGB
        // are equal); normalise from [0, 255] → [0, 1] then re-
        // centre to [-0.5, +0.5] so a midway pixel reads as the
        // baseline height.
        var pix = srcPx[(sy * srcW + sx) * 4]
        var raw = pix / 255 - 0.5
        // Soft radial falloff so the bundle's outer ring sinks
        // below water — gives the island a defined coastline
        // rather than fading abruptly at the mesh edge.
        var dx = (i - cx) / radius
        var d2 = dx * dx + dz * dz
        var t = 1 - d2
        if (t < 0) t = 0
        if (t > 1) t = 1
        var falloff = t * t * (3 - 2 * t)
        heights[j * terrainW + i] = raw * falloff - 0.5 * (1 - falloff)
        i = i + 1
      }
      j = j + 1
    }
    // Smooth the heightmap with a couple of 3 × 3 box-filter
    // passes so the sharp value-noise spikes round into rolling
    // hills instead of cracked peaks. Each pass replaces every
    // cell with the average of its 3×3 neighbourhood; two passes
    // is enough to fold the worst of the plateau noise edges
    // without losing the macro topography.
    var smoothed = Float32Array.new(terrainW * terrainD)
    var passes = 2
    var pass = 0
    while (pass < passes) {
      var sj = 0
      while (sj < terrainD) {
        var si = 0
        while (si < terrainW) {
          var sum = 0
          var count = 0
          var dj = -1
          while (dj <= 1) {
            var rj = sj + dj
            if (rj >= 0 && rj < terrainD) {
              var di = -1
              while (di <= 1) {
                var ri = si + di
                if (ri >= 0 && ri < terrainW) {
                  sum = sum + heights[rj * terrainW + ri]
                  count = count + 1
                }
                di = di + 1
              }
            }
            dj = dj + 1
          }
          smoothed[sj * terrainW + si] = sum / count
          si = si + 1
        }
        sj = sj + 1
      }
      // Swap (copy back) for the next pass; can't reassign
      // `heights` here without confusing the closures further down.
      var ci = 0
      while (ci < terrainW * terrainD) {
        heights[ci] = smoothed[ci]
        ci = ci + 1
      }
      pass = pass + 1
    }
    _terrainHeights = heights
    _terrainCols = terrainW
    _terrainRows = terrainD
    _terrainMesh = Terrain.meshFromHeightmap(g.device, heights, terrainW, terrainD, {
      "stepX": terrainStep,
      "stepZ": terrainStep,
      "amplitude": terrainAmp
    })
    // Topographic colour bands. Sand at the shore, bright grass on
    // plains, darker forest at altitude, rocky tops. Generated as
    // a width × depth texture indexed 1:1 by mesh UV — the colour
    // ramp comes out of the height field directly, no separate
    // shader work. The plateau normal map still rides on top for
    // micro-relief.
    var topoBytes = ByteArray.new(terrainW * terrainD * 4)
    var k = 0
    var jj = 0
    while (jj < terrainD) {
      var ii = 0
      while (ii < terrainW) {
        var hRaw = heights[jj * terrainW + ii]
        var y = hRaw * terrainAmp
        var r = 0
        var gC = 0
        var b = 0
        if (y < -2.5) {
          // Submerged sea floor — a dim wet-sand colour. The water
          // alpha blend tints it blue at depth so a near-neutral
          // brown reads correctly through the body; pure black or
          // navy here just punches a hole at the shore.
          r = 140
          gC = 128
          b = 96
        } else if (y < 0.3) {
          // Wet sand / beach shoreline.
          r = 224
          gC = 206
          b = 142
        } else if (y < 1.6) {
          // Plain land — bright brown+green mix (soil with grass).
          r = 168
          gC = 170
          b = 80
        } else if (y < 3.5) {
          // Plateau forest — saturated green.
          r = 78
          gC = 140
          b = 56
        } else if (y < 5.0) {
          // Rocky transition (light grey, sparse vegetation).
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
      "width":  terrainW,
      "height": terrainD,
      "format": "rgba8unorm-srgb",
      "usage":  ["texture-binding", "copy-dst"],
      "label":  "terrain-topo-palette"
    })
    g.device.writeTexture(topoTex, topoBytes, {
      "width":       terrainW,
      "height":      terrainD,
      "bytesPerRow": terrainW * 4
    })
    var normalImg = Image.decode(heightDb.bytes("value-noise-plateau_normal_1024.png"))
    var normalTex = g.device.uploadImage(normalImg, { "format": "rgba8unorm", "label": "terrain-normal" })
    _terrainMat = Material.new(Vec4.new(1.0, 1.0, 1.0, 1.0))
    _terrainMat.albedoTexture = topoTex
    _terrainMat.normalTexture = normalTex
    _terrainMat.roughnessFactor = 0.85
    _terrainMat.metallicFactor  = 0.0

    // ── Water surface ──────────────────────────────────────────
    // A full-terrain-extent water plane at a moderate y level.
    // Depth buffering does the work: terrain rendered first, then
    // water. The water mesh stays visible only in cells where the
    // terrain is BELOW the water y (the valleys); terrain higher
    // than the water y occludes the plane underneath. The result
    // is a network of ponds following every natural basin instead
    // of one square pond at the lowest noise sample.
    // Build the water plane centred on y=0 and translate at draw
    // time so the HUD slider can move the ocean up/down without
    // rebuilding the mesh. Land-to-water ratio is driven by
    // `_waterYRef["v"]` (live) and `_terrainAmpRef["v"]` (terrain
    // gets Y-scaled in its model matrix), both wired to the HUD
    // panel below.
    _terrainAmpBase = _terrainAmp
    _terrainAmpRef  = { "v": _terrainAmp }
    _waterYRef      = { "v": -1.5 }
    _waterY         = _waterYRef["v"]
    // High subdivision so wave_h interpolation reads smooth at
    // close zoom. 192 cells × 1.6m terrainSize gives ~0.8 m
    // faces — well under the wavelength so curved peaks survive
    // the triangle rasterisation. The cost is ~37 k vertices /
    // ~73 k triangles, a single drawIndexed call.
    _waterMesh = Water.makePlane(g.device, {
      "size":         _terrainSize,
      "subdivisions": 192,
      "y":            0,
      "originX":      -_terrainSize / 2,
      "originZ":      -_terrainSize / 2
    })

    // ── Foliage ─────────────────────────────────────────────────
    // Quaternius nature-kit variants (CC0 1.0 / @Quaternius). Five
    // models keep the existing palette-bucket scatter: noise picks
    // a bucket per site, the bucket selects which set of
    // primitives renders. Trees ship with separate bark / leaves
    // primitives, so each bucket is a LIST of primitives — every
    // bucket's instance buffer drives one drawIndexed per primitive.
    _foliagePrims = []  // List<List<GltfPrimitive>>, indexed by bucket
    // Order: most → least dense. The scatter's bucket-selection
    // weights below give grass the lion's share, bushes a chunk in
    // the middle, and trees the long tail. Reordering the list
    // changes the density mapping; do both together.
    var nature = [
      "nature-kit/Grass_Common_Short.gltf",     // 0 — densest cover
      "nature-kit/Bush_Common.gltf",             // 1 — common bush
      "nature-kit/Bush_Common_Flowers.gltf",     // 2 — flowering bush
      "nature-kit/CommonTree_3.gltf",            // 3 — small tree
      "nature-kit/CommonTree_1.gltf"             // 4 — large tree, sparsest
    ]
    // Per-bucket world-scale multiplier. Quaternius models ship at
    // a unit-ish scale that doesn't match our 150 m terrain — grass
    // tufts read as 1 m bushes, trees read as 1 m shrubs. Scale to
    // a believable real-world height: ~0.4 m grass, ~0.8 m bushes,
    // ~4-6 m trees.
    // World-scale tuning: the island is ~150 m across, so real-life
    // trees would top out at ~10-15 m and bushes at ~1 m. Quaternius
    // native units are model-local; these factors land everything
    // in roughly the right ratio.
    //                grass  bush_c bush_f tree_s tree_l
    _foliageScale = [ 0.45,  0.55,  0.55,  1.0,   1.5 ]
    // Per-bucket sway, split across primitives. Quaternius trees
    // ship as (bark, leaves) — bark must be stiff or the trunk
    // visibly buckles, leaves can sway gently. Grass + bushes are
    // single-primitive, so primSwayFor_(bucket, i) returns the same
    // value for both indices.
    //                 grass  bush_c bush_f tree_s tree_l
    var primaryS  = [ 0.85,  0.45,  0.45,  0.02,  0.01 ]
    var leafS     = [ 0.85,  0.45,  0.45,  0.18,  0.12 ]
    var bi = 0
    while (bi < nature.count) {
      var path = nature[bi]
      var doc = Gltf.fromAssetsDir(g.device, heightDb, path)
      var prims = []
      var sourcePrims = doc.meshes[0].primitives
      var pIdx = 0
      while (pIdx < sourcePrims.count) {
        var prim = sourcePrims[pIdx]
        if (prim.mesh != null) {
          var swayV = primaryS[bi]
          if (pIdx > 0) swayV = leafS[bi]
          prim.material.sway = swayV
          prims.add(prim)
        }
        pIdx = pIdx + 1
      }
      if (prims.count == 0) Fiber.abort("procedural-world: no usable primitives in %(path)")
      _foliagePrims.add(prims)
      bi = bi + 1
    }

    // ── HUD ─────────────────────────────────────────────────────
    // Surface-pixel coords so the panel always anchors to the
    // window's actual top-left corner (a contain projection would
    // sit in letterbox space on off-aspect windows). The panel's
    // width is recomputed on every resize so it scales with the
    // surface; HUDPanel internals (font scale, row height) stay
    // at their library defaults until we bump @hatch:hud with a
    // scale parameter.
    _hud      = HUD.new(g)
    _hudCamera = Camera2D.new(g.width, g.height)
    _hudRenderer = Renderer2D.new(g.device, g.surfaceFormat, g.depthFormat)
    _panelBottom = 600     // first-frame upper bound; rebuilt on resize
    rebuildHudPanel_(g.width, g.height)
    // Stable ref so the density slider can mutate a field across
    // frames without us re-allocating the wrapper Map.
    // The base scatter pre-filter (gates which sites survive the
    // water/cliff/peak thresholds at all). Bucket-specific density
    // is applied on top of this at rebuild time so grass can be
    // dense while bushes/trees stay sparse.
    _densityRef = { "v": 0.07 }
    _foliageDensity = _densityRef["v"]
    // Per-class dropout applied during matrix rebuild — separate
    // sliders for grass vs everything else so the user can dial
    // a thick lawn without flooding the island with bushes.
    _grassDensityRef = { "v": 0.95 }
    _otherDensityRef = { "v": 0.60 }
    _bakedGrassDensity = _grassDensityRef["v"]
    _bakedOtherDensity = _otherDensityRef["v"]
    _bakedScatterDensity = _densityRef["v"]

    // ── Stats ───────────────────────────────────────────────────
    _fpsCounter   = 0
    _fpsTimer     = 0
    _fps          = 0
    _visibleCount = 0
    _culledCount  = 0

    // ── Foliage scatter (first build) ───────────────────────────
    rescatterFoliage_()

    // Per-bucket instance buffer sizes match the natural density
    // profile of each foliage type: grass dominates a real field,
    // trees are rare. Sizes are chosen so the buffers don't
    // overflow under the fine-spaced scatter below.
    //   bucket 0: Grass (dense)        — 80000
    //   bucket 1: Bush_Common          — 12000
    //   bucket 2: Bush_Common_Flowers  — 8000
    //   bucket 3: CommonTree_3 (small) — 2000
    //   bucket 4: CommonTree_1 (large) — 800
    _foliageBufs   = []
    _foliageFloats = []
    _foliageCounts = [0, 0, 0, 0, 0]
    // Capacities sized for the dense scatter: grass tufts dominate
    // (one per 0.35 m × 0.35 m cell over the island ≈ 80 k), bushes
    // fill the middle band, trees stay rare.
    _foliageCapacity = [250000, 30000, 12000, 4000, 1500]
    _foliageDirty = true
    _foliageUploadDirty = true
    _foliageBakedAmpScale = 1.0
    for (i in 0..._foliagePrims.count) {
      var cap = _foliageCapacity[i]
      _foliageBufs.add(g.device.createBuffer({
        "size":  cap * 32 * 4,
        "usage": ["storage", "copy-dst"],
        "label": "foliage-instances-%(i)"
      }))
      _foliageFloats.add(Float32Array.new(cap * 32))
    }
  }

  // Recompute the panel anchor + width from the surface size and
  // rebuild HUDPanel. _activeSlider state in the old panel is
  // discarded (no widget is mid-drag right after a window resize
  // — the user has both hands off the mouse to drag the window
  // edge), so the rebuild is cheap.
  rebuildHudPanel_(w, h) {
    _panelX = 16
    _panelY = 16
    // Pick an integer scale that keeps widgets legible on a high-
    // DPI surface — scale 1 = native HUD font (5×7 px), scale 2
    // doubles every dimension. The threshold tracks roughly the
    // physical pixel density of a typical Retina display.
    var scale = h >= 1100 ? 2 : 1
    _hudScale = scale
    // Panel grows with the window, sized in scaled units so the
    // band reads as wide on a big window regardless of scale.
    var w22 = (w * 0.22).floor
    var minW = 260 * scale
    var maxW = 520 * scale
    if (w22 < minW) w22 = minW
    if (w22 > maxW) w22 = maxW
    _panelW = w22
    _panel = HUDPanel.new(_hud, {
      "x": _panelX, "y": _panelY, "width": _panelW, "title": "WORLD", "scale": scale
    })
  }

  rebuildCameraView_() {
    // Spherical → eye position around the target. Pitch 0 is
    // dead horizontal (side view), π/2 is straight overhead.
    // No fixed elevation bias — Q/E moves the target's Y so the
    // user can frame a ground-level shot without the camera
    // dropping below the terrain.
    var cy = _pitch.cos
    var ex = _distance * _yaw.cos * cy + _target.x
    var ey = _distance * _pitch.sin + _target.y
    var ez = _distance * _yaw.sin * cy + _target.z
    _camera.lookAt(Vec3.new(ex, ey, ez), _target, Vec3.new(0, 1, 0))
  }

  // Pick foliage placements + their palette assignment via noise
  // density. Called at setup and whenever a HUD slider changes
  // the threshold or seed.
  rescatterFoliage_() {
    var half = _terrainSize / 2
    var seedLocal       = _seed
    var densityLocal    = _foliageDensity
    var terrainAmpLocal = _terrainAmp
    var stepLocal       = _terrainStep
    var heightsLocal    = _terrainHeights
    var colsLocal       = _terrainCols
    var rowsLocal       = _terrainRows
    var originXLocal    = -half
    var originZLocal    = -half
    var waterYLocal     = _waterY
    // Sample terrain Y at world (x, z) by bilinearly interpolating
    // the heightmap — matches what the terrain MESH renders since
    // its triangle rasterisation interpolates between vertex
    // heights. A floor-based nearest-cell lookup picks the nearest
    // grid corner, which can sit metres above or below the actual
    // surface on a sloped tile; foliage placed against that value
    // pops above or sinks below the terrain as the amp slider
    // scales the discrepancy.
    var heightAt = Fn.new {|x, z|
      var fx = (x - originXLocal) / stepLocal
      var fz = (z - originZLocal) / stepLocal
      var i0 = fx.floor
      var j0 = fz.floor
      var tx = fx - i0
      var tz = fz - j0
      if (i0 < 0) {
        i0 = 0
        tx = 0
      }
      if (i0 >= colsLocal - 1) {
        i0 = colsLocal - 2
        tx = 1
      }
      if (j0 < 0) {
        j0 = 0
        tz = 0
      }
      if (j0 >= rowsLocal - 1) {
        j0 = rowsLocal - 2
        tz = 1
      }
      var h00 = heightsLocal[j0 * colsLocal + i0]
      var h10 = heightsLocal[j0 * colsLocal + i0 + 1]
      var h01 = heightsLocal[(j0 + 1) * colsLocal + i0]
      var h11 = heightsLocal[(j0 + 1) * colsLocal + i0 + 1]
      var h0  = h00 + (h10 - h00) * tx
      var h1  = h01 + (h11 - h01) * tx
      return (h0 + (h1 - h0) * tz) * terrainAmpLocal
    }
    // Slope estimator. Samples the heightmap one step away on
    // each axis and returns the magnitude of the gradient — high
    // values are cliffs, low values are plains. Foliage prefers
    // plains so the cliff faces of plateau edges stay bare.
    var slopeAt = Fn.new {|x, z|
      var s = stepLocal
      var h  = heightAt.call(x, z)
      var hx = heightAt.call(x + s, z)
      var hz = heightAt.call(x, z + s)
      var dx = hx - h
      var dz = hz - h
      return (dx * dx + dz * dz).sqrt
    }
    var sites = Foliage.scatter({
      "bounds":  [-half * 0.95, -half * 0.95, half * 0.95, half * 0.95],
      // Tight spacing for a dense grass field — the bucket weight
      // table below thins trees back down so they stay rare even
      // at this resolution.
      "spacing": 0.20,
      "jitter":  0.55,
      "seed":    seedLocal + 9999,
      "threshold": Fn.new {|x, z|
        // Site-validity only — submerged, summit, or cliff sites
        // get culled here. Density is applied per-class downstream
        // in `rebuildFoliageMatrices_` so the grass slider and the
        // scatter slider thin grass and non-grass independently.
        var y = heightAt.call(x, z)
        if (y < waterYLocal + 0.3) return 0
        if (y > terrainAmpLocal * 0.85) return 0
        if (slopeAt.call(x, z) > 1.2) return 0
        return 1.0
      }
    })
    _foliageSites = sites
    var count = sites["count"]
    _foliageYs       = Float32Array.new(count)
    _foliagePalettes = []
    var si = 0
    while (si < count) {
      var x = sites["xs"][si]
      var z = sites["zs"][si]
      _foliageYs[si] = heightAt.call(x, z)
      // Weight bucket selection by foliage type — grass dominates,
      // bushes fill the middle band, trees are the long tail. The
      // noise is sampled at a coarser scale so neighbouring sites
      // share a type, giving the scatter visible patches of grass
      // with the occasional tree rather than salt-and-pepper.
      // Per-site uniform-[0,1] hash. OpenSimplex output is narrowly
      // bounded and biases heavily after rescale-and-clamp; a plain
      // sine-hash gives a flat distribution so the bucket thresholds
      // below actually correspond to their percentages.
      var hashV = (x * 12.9898 + z * 78.233 + seedLocal * 0.31).sin * 43758.5453
      var p = hashV - hashV.floor
      if (p < 0) p = p + 1
      var slot = 0
      if (p >= 0.80)  slot = 1   // bush common      (15%)
      if (p >= 0.95)  slot = 2   // bush flowers     (3%)
      if (p >= 0.98)  slot = 3   // small tree       (1.5%)
      if (p >= 0.995) slot = 4   // large tree       (0.5%)
      _foliagePalettes.add(slot)
      si = si + 1
    }
    _foliageCount = count
    _foliageDirty = true
    _foliageScatterAmp = _terrainAmp
    // Diagnostic histogram of how the SCATTER assigned buckets,
    // independent of the per-class dropout in rebuild. If this
    // shows 0 trees but the rebuild log does too, the scatter is
    // never producing tree sites at all (noise range issue or
    // weight thresholds set too high).
    _paletteHist = [0, 0, 0, 0, 0]
    var hi = 0
    while (hi < _foliagePalettes.count) {
      var b = _foliagePalettes[hi]
      _paletteHist[b] = _paletteHist[b] + 1
      hi = hi + 1
    }
  }

  // Bake every foliage instance's TRS matrix (translation × scale)
  // into the per-bucket Float32Array — once per scatter, plus once
  // whenever the terrain amp slider crosses a small delta. The
  // matrices end up in the layout `Renderer3D.writeInstance`
  // produces (column-major model + normalMat, 32 floats each), so
  // the GPU's instance buffer is a direct copy.
  rebuildFoliageMatrices_(ampScale) {
    var ci = 0
    var cn = _foliageCounts.count
    while (ci < cn) {
      _foliageCounts[ci] = 0
      ci = ci + 1
    }
    var xs = _foliageSites["xs"]
    var zs = _foliageSites["zs"]
    var ys = _foliageYs
    var palettes = _foliagePalettes
    var scales   = _foliageScale
    var caps     = _foliageCapacity
    var buckets  = _foliageFloats
    var counts   = _foliageCounts
    var grassDensity   = _grassDensityRef["v"]
    var otherDensity   = _otherDensityRef["v"]
    var scatterDensity = _densityRef["v"]
    // Pre-multiplied non-grass keep rate. Avoids repeated map
    // indexing in the hot loop (and skirts whatever upvalue path
    // was tripping when we read `_densityRef["v"]` per iteration).
    var nonGrassKeep = otherDensity * scatterDensity
    var seedLocal    = _seed
    var i = 0
    while (i < _foliageCount) {
      var bucket = palettes[i]
      // Per-class dropout via a uniform-[0,1] hash. Grass is gated
      // only by the grass slider; non-grass by foliage × scatter
      // (so the scatter slider thins trees/bushes without touching
      // grass coverage).
      var dh = (xs[i] * 9.7531 + zs[i] * 23.197 + seedLocal * 0.137).sin * 87412.3
      var dropoutSample = dh - dh.floor
      if (dropoutSample < 0) dropoutSample = dropoutSample + 1
      var keep = nonGrassKeep
      if (bucket == 0) keep = grassDensity
      if (dropoutSample > keep) {
        i = i + 1
        continue
      }
      var slot   = counts[bucket]
      if (slot >= caps[bucket]) {
        i = i + 1
        continue
      }
      var s = scales[bucket]
      var arr = buckets[bucket]
      var off = slot * 32
      var x = xs[i]
      var y = ys[i] * ampScale
      var z = zs[i]
      // Column-major model matrix (4 rows × 4 cols) for a uniform
      // scale + translation:
      //   col0 = (s, 0, 0, 0)
      //   col1 = (0, s, 0, 0)
      //   col2 = (0, 0, s, 0)
      //   col3 = (x, y, z, 1)
      arr[off]      = s
      arr[off + 1]  = 0
      arr[off + 2]  = 0
      arr[off + 3]  = 0
      arr[off + 4]  = 0
      arr[off + 5]  = s
      arr[off + 6]  = 0
      arr[off + 7]  = 0
      arr[off + 8]  = 0
      arr[off + 9]  = 0
      arr[off + 10] = s
      arr[off + 11] = 0
      arr[off + 12] = x
      arr[off + 13] = y
      arr[off + 14] = z
      arr[off + 15] = 1
      // Normal matrix — same as model for uniform scale; shader
      // re-normalises, so the magnitude bias from `s` is harmless.
      arr[off + 16] = s
      arr[off + 17] = 0
      arr[off + 18] = 0
      arr[off + 19] = 0
      arr[off + 20] = 0
      arr[off + 21] = s
      arr[off + 22] = 0
      arr[off + 23] = 0
      arr[off + 24] = 0
      arr[off + 25] = 0
      arr[off + 26] = s
      arr[off + 27] = 0
      arr[off + 28] = x
      arr[off + 29] = y
      arr[off + 30] = z
      arr[off + 31] = 1
      counts[bucket] = slot + 1
      i = i + 1
    }
    _foliageDirty = false
    _foliageUploadDirty = true
    _foliageBakedAmpScale = ampScale
    _bakedGrassDensity = grassDensity
    _bakedOtherDensity = otherDensity
    _bakedScatterDensity = _densityRef["v"]
  }

  resize(g, w, h) {
    // Some platforms emit a resize(0, 0) on minimize; skip those
    // so we don't write a NaN aspect ratio into the projection
    // and ratchet the window down at the next valid resize.
    if (w <= 0 || h <= 0) return
    _camera.setPerspective(_fovY, w / h, 0.5, 600)
    // The framework reallocates the depth texture on resize;
    // rebind the water pipeline's depth-sample slot to the new
    // view so shore foam keeps reading the live attachment.
    _water.setShore(g.depthView, 0.5, 600, _shoreBand)
    // Resize the planar-reflection target to match the new
    // surface so the reflection texture sampling stays 1:1 in
    // screen space.
    _water.resize(w, h)
    // HUD camera matches the new surface in pixel coords; the
    // panel is reconstructed against the new dimensions so its
    // internal hit-test bounds stay in sync with the visible
    // widgets (the panel caches _x/_y/_w at construction).
    _hudCamera = Camera2D.new(w, h)
    rebuildHudPanel_(w, h)
  }

  update(g) {
    if (g.input.justPressed("Escape")) g.requestQuit

    // Mouse-wheel zoom — scroll up = closer, scroll down = farther.
    var wheel = g.input.scrollY
    if (wheel != 0) {
      _distance = _distance - wheel * 2.0
      if (_distance < 6)   _distance = 6
      if (_distance > 240) _distance = 240
      _moved = true
    }
    // Keyboard zoom kept as a backup for users without a wheel.
    var zoomSpeed = 60
    if (g.input.isDown("KeyZ")) {
      _distance = _distance - zoomSpeed * g.dt
      if (_distance < 6) _distance = 6
      _moved = true
    }
    if (g.input.isDown("KeyX")) {
      _distance = _distance + zoomSpeed * g.dt
      if (_distance > 240) _distance = 240
      _moved = true
    }

    // Camera-relative pan. Forward = into the screen along the
    // ground (yaw direction with the pitch flattened); right = 90°
    // clockwise of forward. Both stay on the world XZ plane so
    // motion stays grounded.
    var panSpeed = 32
    var forwardX = -_yaw.cos
    var forwardZ = -_yaw.sin
    var rightX   = -_yaw.sin
    var rightZ   = _yaw.cos
    var dx = 0
    var dz = 0
    if (g.input.isDown("KeyW")) {
      dx = dx + forwardX
      dz = dz + forwardZ
    }
    if (g.input.isDown("KeyS")) {
      dx = dx - forwardX
      dz = dz - forwardZ
    }
    if (g.input.isDown("KeyD")) {
      dx = dx + rightX
      dz = dz + rightZ
    }
    if (g.input.isDown("KeyA")) {
      dx = dx - rightX
      dz = dz - rightZ
    }
    if (dx != 0 || dz != 0) {
      var step = panSpeed * g.dt
      _target = Vec3.new(_target.x + dx * step, _target.y, _target.z + dz * step)
      _moved = true
    }

    if (_moved) {
      rebuildCameraView_()
      _moved = false
    }

    // Mouse-drag orbit. Skip drags that start inside the HUD
    // panel's current bounds. Surface-pixel coords throughout; the
    // panel's _panelX / _panelY / _panelW are recomputed in
    // rebuildHudPanel_ on every resize.
    if (g.input.mouseJustPressed("left")) {
      var mx = g.input.mouseX
      var my = g.input.mouseY
      var insidePanel = mx >= _panelX && mx < _panelX + _panelW &&
                        my >= _panelY && my < _panelBottom
      if (!insidePanel) {
        _drag = true
        _dragX = mx
        _dragY = my
      }
    }
    if (g.input.mouseJustReleased("left")) _drag = false
    if (_drag) {
      var dx = g.input.mouseX - _dragX
      var dy = g.input.mouseY - _dragY
      _dragX = g.input.mouseX
      _dragY = g.input.mouseY
      _yaw   = _yaw + dx * 0.005
      _pitch = _pitch - dy * 0.005
      if (_pitch < 0.0)  _pitch = 0.0       // full horizontal side view
      if (_pitch > 1.5)  _pitch = 1.5
      rebuildCameraView_()
    }

    // Q / E nudge the target's Y so you can raise / lower the
    // entire frame — handy for ground-level shots looking up at
    // a plateau, or top-down spectator views.
    if (g.input.isDown("KeyQ")) {
      _target = Vec3.new(_target.x, _target.y + 30 * g.dt, _target.z)
      _moved = true
    }
    if (g.input.isDown("KeyE")) {
      _target = Vec3.new(_target.x, _target.y - 30 * g.dt, _target.z)
      _moved = true
    }

    // Track FPS so the HUD has something to show.
    _fpsCounter = _fpsCounter + 1
    _fpsTimer   = _fpsTimer + g.dt
    if (_fpsTimer >= 0.5) {
      _fps = _fpsCounter / _fpsTimer
      _fpsCounter = 0
      _fpsTimer = 0
    }
  }

  draw(g) {
    // ── 3D pass ─────────────────────────────────────────────────
    var pass = g.pass

    // Live HUD knobs: scale terrain Y by the slider ratio and
    // resync the foliage-height lookup amplitude so cubes stay
    // pinned to the surface as the user dials terrain amp.
    _terrainAmp     = _terrainAmpRef["v"]
    _waterY         = _waterYRef["v"]
    var ampScale    = _terrainAmp / _terrainAmpBase
    var terrainModel = Mat4.scale(1, ampScale, 1)
    var waterModel  = Mat4.translation(0, _waterY, 0)

    // Build a mirror camera once for the planar-reflection pass
    // that runs at the end of this frame. Reflecting eye + target
    // across the water plane (y = _waterY) and flipping the up
    // vector gives a properly handed reflected view; the
    // projection stays the same since FoV is unchanged.
    var eye = _camera.eye
    var tgt = _camera.target
    var mirrorEye = Vec3.new(eye.x, 2 * _waterY - eye.y, eye.z)
    var mirrorTgt = Vec3.new(tgt.x, 2 * _waterY - tgt.y, tgt.z)
    _mirrorCamera.setPerspective(_fovY, g.width / g.height, 0.5, 600)
    _mirrorCamera.lookAt(mirrorEye, mirrorTgt, Vec3.new(0, -1, 0))

    // Terrain through Renderer3D's PBR pipeline.
    _renderer.beginFrame(pass, _camera)
    _renderer.setAmbient(_ambient, _ambientInt)
    _renderer.addDirectional(_sunDir, _sunColor, _sunIntensity, false)
    // Wind: base direction + base strength + gust modulation. Gust
    // adds extra punch on top of the base; both feed the foliage
    // sway in the vertex shader.
    var windStr = _windOpts["baseStrength"] * (1 + _windOpts["gust"] * 0.7)
    _renderer.setWind(_windOpts["baseX"], _windOpts["baseZ"], windStr)
    _renderer.setWindTime(g.elapsed)
    _renderer.draw(_terrainMesh, _terrainMat, terrainModel)

    // Foliage: matrices are precomputed and only rebuilt when
    // scatter or terrain amp changes. The per-frame cost collapses
    // to 5 buffer uploads + ~10 instanced draw calls — no Wren
    // bytecode loop over 30k instances every frame.
    if (_flags["showFoliage"]) {
      if ((_terrainAmp - _foliageScatterAmp).abs > 0.5) {
        rescatterFoliage_()
        rebuildFoliageMatrices_(ampScale)
      } else {
        var needsRebuild = _foliageDirty ||
          (ampScale - _foliageBakedAmpScale).abs > 0.001 ||
          (_grassDensityRef["v"] - _bakedGrassDensity).abs > 0.005 ||
          (_otherDensityRef["v"] - _bakedOtherDensity).abs > 0.005 ||
          (_densityRef["v"]      - _bakedScatterDensity).abs > 0.005
        if (needsRebuild) rebuildFoliageMatrices_(ampScale)
      }
      var bi = 0
      var bn = _foliageFloats.count
      while (bi < bn) {
        var n = _foliageCounts[bi]
        if (n > 0) {
          if (_foliageUploadDirty) {
            _foliageBufs[bi].writeFloatsN(0, _foliageFloats[bi], n * 32)
          }
          var prims = _foliagePrims[bi]
          var pi = 0
          var pn = prims.count
          while (pi < pn) {
            var prim = prims[pi]
            _renderer.drawMeshInstanced(prim.mesh, prim.material, _foliageBufs[bi], n)
            pi = pi + 1
          }
        }
        bi = bi + 1
      }
      if (_foliageUploadDirty) _foliageUploadDirty = false
    }
    _visibleCount = _foliageCounts[0] + _foliageCounts[1] + _foliageCounts[2] + _foliageCounts[3] + _foliageCounts[4]
    _culledCount  = 0
    _renderer.endFrame()

    // End the terrain pass so we can re-open a follow-up where the
    // depth attachment is bound read-only. WebGPU forbids sampling
    // a depth texture that the current pass is also writing to, and
    // the water shader needs the scene depth to fade in shore foam
    // along the coastline.
    pass.end
    pass = g.encoder.beginRenderPass({
      "colorAttachments": [{
        "view":     g.colorView,
        "loadOp":   "load",
        "storeOp":  "store"
      }],
      "depthStencilAttachment": {
        "view":          g.depthView,
        "depthLoadOp":   "load",
        "depthStoreOp":  "store",
        "depthReadOnly": true
      }
    })
    g.pass = pass

    _waterTime = _flags["pauseWater"] ? 0 : g.elapsed
    // Wind drives water: base strength + direction feed the flow
    // (chop drifts along the wind vector), gust raises wave
    // amplitude proportionally so gustier days read as choppier
    // seas. Keeps the wind sliders connected to something visible
    // without needing a foliage-sway shader yet.
    var amp = _waveOpts["amplitude"] * (1 + _windOpts["gust"])
    _water.setWave(amp, _waveOpts["scale"], _waveOpts["timeScale"])
    // Stylised teal — matches the saturated, slightly-warm
    // Quaternius nature-kit palette better than the previous near-
    // black navy. At high alpha the body now reads as tropical
    // water, not a dark hole.
    _water.setColors([0.22, 0.58, 0.65, _waterAlphaRef["v"]], [0.60, 0.82, 0.92], 3.5)
    _water.setFoam([0.95, 0.98, 1.0], _foamThreshRef["v"])
    _water.setFlow(_windOpts["baseX"], _windOpts["baseZ"], _windOpts["baseStrength"] * 0.08)
    _water.setShoreBand(_shoreBandRef["v"])
    _water.beginFrame(pass, _camera, _waterTime)
    _water.draw(_waterMesh, waterModel)
    _water.endFrame()

    // ── HUD overlay ────────────────────────────────────────────
    _hudRenderer.beginFrame(_hudCamera)
    _hudRenderer.beginPass(g.pass)
    _hud.beginFrame(g, _hudRenderer)
    _panel.beginFrame()
    _panel.text("FPS", _fps.round)
    _panel.text("grass",   "%(_foliageCounts[0]) / %(_paletteHist[0])")
    _panel.text("bush c",  "%(_foliageCounts[1]) / %(_paletteHist[1])")
    _panel.text("bush f",  "%(_foliageCounts[2]) / %(_paletteHist[2])")
    _panel.text("tree s",  "%(_foliageCounts[3]) / %(_paletteHist[3])")
    _panel.text("tree l",  "%(_foliageCounts[4]) / %(_paletteHist[4])")
    _panel.divider()
    // Amp ceiling sized against the terrain's nearshore relief —
    // anything beyond ~0.3 m crests above the sand band and reads
    // as the ocean flooding the island. Freq up to 1.5/m gives
    // chop; below 0.3/m reads as long swell.
    _panel.slider("water amp",  _waveOpts, "amplitude", 0.0, 0.3)
    _panel.slider("water freq", _waveOpts, "scale",     0.1, 1.5)
    _panel.slider("water time", _waveOpts, "timeScale", 0.0, 2.0)
    _panel.slider("alpha",      _waterAlphaRef,   "v",  0.0, 1.0)
    // Foam threshold is opt-in: at 1.0 the crest smoothstep never
    // fires (clean water + just specular highlights). Drop the
    // slider toward 0.4 only when you want chop foam on the open
    // surface.
    _panel.slider("foam",       _foamThreshRef,   "v",  0.4, 1.0)
    _panel.slider("shore band", _shoreBandRef,    "v",  0.2, 5.0)
    _panel.toggle("pause water", _flags, "pauseWater")
    _panel.toggle("reflection",  _flags, "reflection")
    _panel.divider()
    _panel.slider("wind base", _windOpts, "baseStrength", 0, 4)
    _panel.slider("wind gust", _windOpts, "gust",         0, 2)
    _panel.divider()
    // Land-to-water ratio. `terrain amp` Y-scales the prebuilt
    // terrain mesh (cheap — vertex shader applies the model
    // matrix); `water y` slides the ocean plane up or down.
    // Raise water and/or lower terrain to drown more of the
    // island; lower water and/or raise terrain to expose more
    // ground.
    _panel.slider("terrain amp", _terrainAmpRef, "v", 2.0, 18.0)
    _panel.slider("water y",     _waterYRef,     "v", -6.0, 4.0)
    _panel.divider()
    _panel.toggle("foliage", _flags, "showFoliage")
    _panel.slider("grass",   _grassDensityRef, "v", 0.0, 1.0)
    _panel.slider("foliage", _otherDensityRef, "v", 0.0, 1.0)
    _panel.slider("scatter", _densityRef,      "v", 0.0, 1.0)
    _hud.endFrame
    _hudRenderer.endPass()
    _hudRenderer.flush(g.pass)

    // ── Planar reflection pass ────────────────────────────────
    // Close the water/HUD pass, then render the scene one more
    // time from a camera mirrored across the water plane into
    // water's offscreen reflection target. The water shader will
    // sample THIS frame's output on the NEXT frame (one-frame lag,
    // invisible at typical camera motion).
    if (_flags["reflection"]) {
      g.pass.end
      var reflPass = _water.beginReflectionPass(g.encoder,
        [0.45, 0.62, 0.78, 1.0])
      _renderer.beginFrame(reflPass, _mirrorCamera)
      _renderer.setAmbient(_ambient, _ambientInt)
      _renderer.addDirectional(_sunDir, _sunColor, _sunIntensity, false)
      _renderer.draw(_terrainMesh, _terrainMat, terrainModel)
      if (_flags["showFoliage"]) {
        for (i in 0..._foliageFloats.count) {
          var n = _foliageCounts[i]
          if (n == 0) continue
          for (prim in _foliagePrims[i]) {
            _renderer.drawMeshInstanced(
              prim.mesh, prim.material, _foliageBufs[i], n)
          }
        }
      }
      _renderer.endFrame()
      reflPass.end
      g.pass = null
    }

    // (Scatter density change no longer requires rescatter — the
    // threshold callback returns 1.0 for valid sites, and the
    // scatter slider now multiplies into the non-grass dropout
    // applied during matrix rebuild.)
  }

  destroy {
    _water.destroy
    _renderer.destroy
    _foliageBufs.each {|b| b.destroy }
  }
}

Game.run(ProceduralWorld)
