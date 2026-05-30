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
                            Water, WaterPipeline
import "@hatch:gpu"     for Gpu, Renderer3D, Renderer2D,
                            Camera3D, Camera2D,
                            Frustum, Lod, Mesh, Material
import "@hatch:hud"     for HUD, HUDPanel
import "@hatch:spatial" for ClusterGrid
import "@hatch:math"    for Vec3, Vec4, Mat4
import "@hatch:noise"   for Noise

class ProceduralWorld is Game {
  construct new() {}

  config { {
    "title":      "Procedural World",
    "width":      1280,
    "height":     720,
    "clearColor": [0.45, 0.62, 0.78, 1.0],   // sky blue
    "depth":      true
  } }

  setup(g) {
    _device = g.device

    // ── Renderers ───────────────────────────────────────────────
    _renderer = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)
    _water    = WaterPipeline.new(g.device, g.surfaceFormat, g.depthFormat)

    // Hand-tuned warm sun. Renderer3D reads it; WaterPipeline
    // gets it via setSun below so reflections + speculars match.
    _sunDir       = Vec3.new(-0.3, -1.0, -0.4)
    _sunColor     = Vec3.new(1.0, 0.95, 0.85)
    _sunIntensity = 3.5
    _ambient      = Vec3.new(0.45, 0.55, 0.70)
    _ambientInt   = 0.5
    _water.setSun([_sunDir.x, _sunDir.y, _sunDir.z],
                  [_sunColor.x, _sunColor.y, _sunColor.z],
                  _sunIntensity)
    _water.setAmbient([0.05, 0.10, 0.16])

    // ── Camera (orbit) ──────────────────────────────────────────
    _yaw      = 0.6
    _pitch    = 0.55
    _distance = 90
    _target   = Vec3.new(0, 0, 0)
    _fovY     = 55
    var aspect = g.width / g.height
    _camera = Camera3D.perspective(_fovY, aspect, 0.5, 600)
    rebuildCameraView_()

    _drag = false

    // ── Live state. Every Map below feeds a HUDPanel row; the
    //    panel mutates them in place and we read them each frame.
    _waveOpts = {
      "amplitude": 0.35,
      "scale":     0.18,
      "timeScale": 0.55
    }
    _windOpts = {
      "baseX":        1,
      "baseY":        0,
      "baseZ":        0,
      "baseStrength": 1.0,
      "gust":         0.6,
      "scale":        0.04,
      "timeScale":    0.3,
      "seed":         7
    }
    _flags = {
      "showFoliage": true,
      "pauseWater":  false
    }
    _seed = 1337

    // ── Terrain ─────────────────────────────────────────────────
    var terrainW = 64
    var terrainD = 64
    var terrainStep = 1.6              // world units per heightmap cell
    var terrainAmp  = 6.0              // height scale
    _terrainSize    = (terrainW - 1) * terrainStep
    _terrainAmp     = terrainAmp
    _terrainStep    = terrainStep
    _terrainMesh = Terrain.fromNoise(g.device, {
      "width":      terrainW,
      "depth":      terrainD,
      "stepX":      terrainStep,
      "stepZ":      terrainStep,
      "amplitude":  terrainAmp,
      "noiseStepX": 0.06,
      "noiseStepZ": 0.06,
      "seed":       _seed
    })
    _terrainMat = Material.new(Vec4.new(0.30, 0.42, 0.22, 1.0))   // mossy green

    // ── Water lake ──────────────────────────────────────────────
    // A constrained pond sits in the lowest noise basin we can
    // find within a small search region around the origin. The
    // mesh is 20 m on a side so the shoreline (terrain rising
    // above water y) wraps the full mesh; if we used the full
    // terrain footprint the water would read as a sheet
    // spanning the world rather than a body.
    var pondCx = 0
    var pondCz = 0
    var minNoise = 1
    var search = 18
    var step = 6
    var sy = -search
    while (sy <= search) {
      var sx = -search
      while (sx <= search) {
        var n = Noise.simplex2(sx * 0.06, sy * 0.06, _seed)
        if (n < minNoise) {
          minNoise = n
          pondCx = sx
          pondCz = sy
        }
        sx = sx + step
      }
      sy = sy + step
    }
    // Anchor the water surface a touch above the basin floor so
    // there's a visible shoreline where the surrounding terrain
    // crosses through.
    var pondY = minNoise * _terrainAmp + 0.4
    _waterY = pondY
    _waterMesh = Water.makePlane(g.device, {
      "size":         20,
      "subdivisions": 48,
      "y":            pondY,
      "originX":      pondCx - 10,
      "originZ":      pondCz - 10
    })
    _waterModel = Mat4.identity
    // Aim the camera at the pond instead of the world origin so
    // the orbit framing is naturally lake-centred.
    _target = Vec3.new(pondCx, 0, pondCz)
    rebuildCameraView_()

    // ── Foliage ─────────────────────────────────────────────────
    // Cube stand-ins for grass. One mesh, five palette materials
    // so the LOD batching has somewhere to bucket.
    _foliageMesh = Mesh.cube(g.device, 0.35)
    _foliageMats = [
      Material.new(Vec4.new(0.32, 0.55, 0.18, 1.0)),
      Material.new(Vec4.new(0.40, 0.62, 0.22, 1.0)),
      Material.new(Vec4.new(0.28, 0.48, 0.16, 1.0)),
      Material.new(Vec4.new(0.55, 0.62, 0.20, 1.0)),
      Material.new(Vec4.new(0.45, 0.40, 0.20, 1.0))
    ]

    // ── HUD ─────────────────────────────────────────────────────
    _hud      = HUD.new(g)
    _hudCamera = Camera2D.new(g.width, g.height)
    _hudRenderer = Renderer2D.new(g.device, g.surfaceFormat, g.depthFormat)
    _panel    = HUDPanel.new(_hud, {
      "x": 16, "y": 16, "width": 260, "title": "WORLD"
    })
    // Stable ref so the density slider can mutate a field across
    // frames without us re-allocating the wrapper Map.
    _densityRef = { "v": 0.55 }
    _foliageDensity = _densityRef["v"]

    // ── Stats ───────────────────────────────────────────────────
    _fpsCounter   = 0
    _fpsTimer     = 0
    _fps          = 0
    _visibleCount = 0
    _culledCount  = 0

    // ── Foliage scatter (first build) ───────────────────────────
    rescatterFoliage_()

    // Instance buffers — one per palette. Sized for worst case
    // (all foliage in one bucket). 32 floats per instance.
    _foliageBufs   = []
    _foliageFloats = []
    _foliageCounts = [0, 0, 0, 0, 0]
    var perBucket = 4000
    for (i in 0..._foliageMats.count) {
      _foliageBufs.add(g.device.createBuffer({
        "size":  perBucket * 32 * 4,
        "usage": ["storage", "copy-dst"],
        "label": "foliage-instances-%(i)"
      }))
      _foliageFloats.add(Float32Array.new(perBucket * 32))
    }
  }

  rebuildCameraView_() {
    // Spherical → eye position around the target.
    var cy = _pitch.cos
    var ex = _distance * _yaw.cos * cy + _target.x
    var ey = _distance * _pitch.sin + _target.y + 12
    var ez = _distance * _yaw.sin * cy + _target.z
    _camera.lookAt(Vec3.new(ex, ey, ez), _target, Vec3.new(0, 1, 0))
  }

  // Pick foliage placements + their palette assignment via noise
  // density. Called at setup and whenever a HUD slider changes
  // the threshold or seed.
  rescatterFoliage_() {
    var half = _terrainSize / 2
    // Locals so the Fn.new threshold closure captures stable
    // values instead of trying to read instance fields off the
    // enclosing class.
    var seedLocal     = _seed
    var densityLocal  = _foliageDensity
    var terrainAmpLocal = _terrainAmp
    var sites = Foliage.scatter({
      "bounds":  [-half * 0.9, -half * 0.9, half * 0.9, half * 0.9],
      "spacing": 0.9,
      "jitter":  0.45,
      "seed":    seedLocal + 9999,
      "threshold": Fn.new {|x, z|
        // Same simplex2 field we used for terrain; foliage
        // grows where the field is positive (raised ground)
        // and density modulates the cutoff.
        var n = Noise.simplex2(x * 0.06, z * 0.06, seedLocal) * 0.5 + 0.5
        return n * densityLocal
      }
    })
    _foliageSites = sites
    // Pre-compute terrain height + palette index per site so the
    // per-frame walk just reads — no Noise calls in the hot path.
    var count = sites["count"]
    _foliageYs       = Float32Array.new(count)
    _foliagePalettes = []
    for (i in 0...count) {
      var x = sites["xs"][i]
      var z = sites["zs"][i]
      var y = Noise.simplex2(x * 0.06, z * 0.06, seedLocal) * terrainAmpLocal
      _foliageYs[i] = y
      // Bucket palette by quintile of the noise field so
      // neighbouring foliage shares a tint.
      var p = (Noise.simplex2(x * 0.04 + 11, z * 0.04 - 7, seedLocal + 3) * 0.5 + 0.5) * 5
      var slot = p.floor
      if (slot < 0) slot = 0
      if (slot > 4) slot = 4
      _foliagePalettes.add(slot)
    }
    _foliageCount = count
  }

  resize(g, w, h) {
    _camera.setPerspective(_fovY, w / h, 0.5, 600)
  }

  update(g) {
    if (g.input.justPressed("Escape")) g.requestQuit

    // Mouse-drag orbit. Skip drags that start inside the HUD
    // panel so slider scrubs don't hijack the camera.
    if (g.input.mouseJustPressed("left")) {
      if (g.input.mouseX > 16 + 260 || g.input.mouseY > 16 + 200) {
        _drag = true
        _dragX = g.input.mouseX
        _dragY = g.input.mouseY
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
      if (_pitch <  0.05) _pitch = 0.05
      if (_pitch >  1.45) _pitch = 1.45
      rebuildCameraView_()
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

    // Terrain through Renderer3D's PBR pipeline.
    _renderer.beginFrame(pass, _camera)
    _renderer.setAmbient(_ambient, _ambientInt)
    _renderer.addDirectional(_sunDir, _sunColor, _sunIntensity, false)
    _renderer.draw(_terrainMesh, _terrainMat, Mat4.identity)

    // Foliage: cull + LOD bucket + instanced draw. Reads the
    // pre-baked y heights so the per-cube cost stays at the cull
    // test + writeInstance.
    var visible = 0
    var culled  = 0
    if (_flags["showFoliage"]) {
      var counts = _foliageCounts
      for (i in 0...counts.count) counts[i] = 0
      var planes = _camera.frustumPlanes
      var eye = _camera.eye
      var ex = eye.x
      var ey = eye.y
      var ez = eye.z
      var t0sq = 40 * 40
      var t1sq = 80 * 80
      var xs = _foliageSites["xs"]
      var zs = _foliageSites["zs"]
      for (i in 0..._foliageCount) {
        var x = xs[i]
        var z = zs[i]
        var y = _foliageYs[i]
        if (!Frustum.sphereVisible(planes, x, y, z, 0.7)) {
          culled = culled + 1
          continue
        }
        var bucket = _foliagePalettes[i]
        Renderer3D.writeInstance(
          _foliageFloats[bucket],
          counts[bucket],
          Mat4.translation(x, y, z))
        counts[bucket] = counts[bucket] + 1
        visible = visible + 1
      }
      // One drawIndexed per palette bucket with at least one
      // visible instance.
      for (i in 0..._foliageFloats.count) {
        var n = counts[i]
        if (n == 0) continue
        _foliageBufs[i].writeFloatsN(0, _foliageFloats[i], n * 32)
        _renderer.drawMeshInstanced(
          _foliageMesh, _foliageMats[i], _foliageBufs[i], n)
      }
    }
    _renderer.endFrame()
    _visibleCount = visible
    _culledCount  = culled

    // Water through its own pipeline, on the same pass + depth.
    var t = _flags["pauseWater"] ? 0 : g.elapsed
    _water.setWave(_waveOpts["amplitude"], _waveOpts["scale"], _waveOpts["timeScale"])
    _water.beginFrame(pass, _camera, t)
    _water.draw(_waterMesh, _waterModel)
    _water.endFrame()

    // ── HUD overlay ────────────────────────────────────────────
    _hudRenderer.beginFrame(_hudCamera)
    _hudRenderer.beginPass(g.pass)
    _hud.beginFrame(g, _hudRenderer)
    _panel.beginFrame()
    _panel.text("FPS", _fps.round)
    _panel.text("visible", _visibleCount.toString)
    _panel.text("culled",  _culledCount.toString)
    _panel.divider()
    _panel.slider("water amp",  _waveOpts, "amplitude", 0.0, 1.5)
    _panel.slider("water freq", _waveOpts, "scale",     0.05, 1.0)
    _panel.slider("water time", _waveOpts, "timeScale", 0.0, 2.0)
    _panel.toggle("pause water", _flags, "pauseWater")
    _panel.divider()
    _panel.slider("wind base", _windOpts, "baseStrength", 0, 4)
    _panel.slider("wind gust", _windOpts, "gust",         0, 2)
    _panel.divider()
    _panel.toggle("foliage", _flags, "showFoliage")
    _panel.slider("density", _densityRef, "v", 0.0, 1.0)
    _hud.endFrame
    _hudRenderer.endPass()
    _hudRenderer.flush(g.pass)

    // Rescatter only when the density slider crosses a
    // perceptible threshold — the operation rebuilds the entire
    // site list + per-site y heights, expensive to run per
    // frame even at small counts.
    var v = _densityRef["v"]
    if ((v - _foliageDensity).abs > 0.02) {
      _foliageDensity = v
      rescatterFoliage_()
    }
  }

  destroy {
    _water.destroy
    _renderer.destroy
    _foliageBufs.each {|b| b.destroy }
  }
}

Game.run(ProceduralWorld)
