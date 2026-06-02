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
                            Water, WaterPipeline,
                            SkyboxPipeline,
                            Weather, Particles,
                            PostFX
import "./knobs"        for Knobs
import "./wind"         for Wind
import "./sun"          for Sun
import "./postfx_setup" for PostFxSetup
import "./topography"   for Topography
import "./foliage_scene"      for FoliageScene
import "@hatch:gpu"     for Gpu, Renderer3D, Renderer2D,
                            Camera3D, Camera2D,
                            Frustum, Lod, Mesh, Material
import "@hatch:hud"     for HUD, HUDPanel
import "@hatch:spatial" for ClusterGrid
import "@hatch:math"    for Vec3, Vec4, Mat4
import "@hatch:noise"   for Noise
import "@hatch:assets"  for Assets
import "@hatch:image"   for Image
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
    // Soft directional shadows. 2048² shadow map across a 90 m
    // half-extent ortho frustum covers the whole island; pcfRadius
    // sets the 3×3 PCF kernel step in shadow-map UV space —
    // 0.0015 reads as a soft 1.5 px feather at 2048 resolution.
    _renderer.enableShadows({
      "size":      2048,
      "extent":    90.0,
      "near":      0.1,
      "far":       250.0,
      "bias":      0.004,
      "pcfRadius": 0.0018
    })
    _water    = WaterPipeline.new(g.device, g.surfaceFormat, g.depthFormat)
    _sky      = SkyboxPipeline.new(g.device, g.surfaceFormat, g.depthFormat)

    // Post-process + sun + wind + scene knobs live in sibling
    // modules so this `setup` stays focused on resource wiring
    // rather than constant tuning. Edit those files to change
    // the look.
    PostFxSetup.apply(g)
    _sun      = Sun.build()
    _knobs    = Knobs.make()
    _windOpts = Wind.make()
    _flags    = _knobs["flags"]
    Sun.applyToScene(_water, _sky, _sun)
    _sky.setSkyGradient([0.30, 0.52, 0.92],   // zenith — saturated blue
                        [0.62, 0.80, 0.98],   // mid    — pale cyan
                        [0.96, 0.86, 0.72])   // horizon — warm sand haze
    _sky.setClouds(0.42, 320.0, 1.4, [1.00, 0.96, 0.88])
    _sky.setWind(0.015, 0.005)

    // Aerial-perspective fog. `end` sits strictly inside the
    // water-mesh radius so the mesh's terminating edge fades into
    // the sky horizon band before the geometry boundary is
    // visible. Linear curve is the predictable choice here — the
    // false-horizon distance is a hard contract (everything past
    // `end` is fully horizon-coloured). Colour binds to the sky's
    // horizon triple so the world's hue matches the visible sky.
    _fog = Weather.fog({"color": [0.96, 0.86, 0.72], "start": 60.0, "end": 130.0, "curve": 0})
    _water.setFog(_fog)
    // Shore foam — sample the scene depth so foam fades in along
    // the coastline. Near/far must match the camera's perspective
    // params below; bandMeters is how deep the terrain can be
    // beneath the water surface before foam fully fades.
    _water.setShore(g.depthView, 0.5, 600, _knobs["shoreBand"]["v"])
    _lastShoreDepthView_ = g.depthView
    // Allocate the planar-reflection target sized to the surface.
    _water.resize(g.width, g.height)
    // Ocean scale: tiny, dense ring spatter. Larger bodies of water
    // call for small cells so rings read as raindrops striking a
    // sheet, not plops in a pond. Pond / lake scenes should use
    // 0.55–0.80 m via the same setter.
    _water.setRippleScale(0.22)
    _water.setRipple(0.0, 0.18, 0.32, 0.55)

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
    _sky.setProjection(_fovY, aspect)
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
    _seed = 1337

    // ── Terrain (sampled from value-noise-plateau PNG) ──────────
    // `hatch run` chdir's into the workspace before invoking the VM,
    // so `Fs.cwd` is this demo's directory regardless of where the
    // user launched from. Plain relative path.
    var heightDb = Assets.open("assets")
    // Heightmap → mesh → palette → normal → material. Lives in
    // topography.wren so this `setup` stays focused on wiring.
    _terrain = Topography.new(g, heightDb)

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
    // `_knobs["waterY"]["v"]` (live) and `_knobs["terrainAmp"]["v"]` (terrain
    // gets Y-scaled in its model matrix), both wired to the HUD
    // panel below.
    _waterY = _knobs["waterY"]["v"]
    // High subdivision so wave_h interpolation reads smooth at
    // close zoom. 192 cells × 1.6m terrainSize gives ~0.8 m
    // faces — well under the wavelength so curved peaks survive
    // the triangle rasterisation. The cost is ~37 k vertices /
    // ~73 k triangles, a single drawIndexed call.
    _waterMesh = Water.makePlane(g.device, {
      "size":         _terrain.size,
      "subdivisions": 192,
      "y":            0,
      "originX":      -_terrain.size / 2,
      "originZ":      -_terrain.size / 2
    })

    // Foliage lives in `foliage.wren`. The class loads Quaternius
    // models, allocates per-bucket instance buffers, runs the
    // first scatter, and exposes `update(ampScale)` / `draw(renderer)`
    // / `setWaterY(y)` for the per-frame loop.

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
    _foliage = FoliageScene.new(g, heightDb, _terrain, _knobs, _waterY, _seed)

    // ── Weather ─────────────────────────────────────────────────
    // 1×1 white pixel as the rain streak sprite — keeps the asset
    // pipeline simple. A real game would load a vertical-streak PNG
    // with soft-edge alpha for nicer-looking drops.
    _rainTex = g.device.createTexture({
      "width": 1, "height": 1, "format": "rgba8unorm",
      "usage": ["texture-binding", "copy-dst"]
    })
    g.device.writeTexture(_rainTex, ByteArray.fromList([255, 255, 255, 255]),
                          {"width": 1, "height": 1, "bytesPerRow": 4})
    // Bigger spawn area + thicker streaks + higher capacity than
    // Weather.rain's defaults: the procedural-world camera looks
    // out across the island from elevation, so a tight column
    // tracking the eye reads as nothing under most orbit angles.
    // The HUD's `rain rate` slider drives `_rain.emissionRate`
    // per frame so the player can dial the storm up or off.
    _rain = Weather.rain(g.device, {
      "texture":   _rainTex,
      // Capacity = max rate × avg-lifetime. At slider max 1500 ×
      // 2.0s avg lifetime we want ~3000 live particles; the 3500
      // budget gives a little headroom without burning CPU on
      // unused slots — every live particle costs an Mat-pack write
      // and a sqrt per frame.
      "capacity":  3500,
      "intensity": 0,          // start off; HUD toggle turns it on
      "area":      [80, 80],
      "fallSpeed": 14,
      // Slim streaks. Real raindrops are sub-mm wide; 0.04 m
      // reads as a thin streak mid-distance while the ~3 m
      // length keeps far streaks legible. Length up, width down
      // — the same total ink, thinner shape.
      "length":    3.0,
      "width":     0.04,
      // Lifetime × fallSpeed = fall distance. 1.8–2.2s × 14m/s
      // ≈ 25–30 m of fall, comfortably tree-canopy → water from
      // a target+20 spawn.
      "lifetime":  [1.8, 2.2],
      // Translucent base — the per-particle alpha further fades
      // close-camera streaks so they read as a diffuse curtain
      // rather than opaque chalk lines. Low alpha so the curtain
      // reads as atmospheric drizzle, not painted lines.
      "color":     [0.82, 0.88, 0.98, 0.32]
    })
    _rain.isPlaying = false   // toggled by the ATMO HUD's "rain" switch
    Particles.register(_rain)

    // ── Stats ───────────────────────────────────────────────────
    _fpsCounter   = 0
    _fpsTimer     = 0
    _fps          = 0
    _visibleCount = 0
    _culledCount  = 0
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
    // Second panel for atmospheric / camera knobs. The main WORLD
    // panel overflows the window past ~25 rows on modest-height
    // displays; splitting the camera+fog controls into their own
    // strip keeps every slider visible without a scrollbar. Pinned
    // to the right edge of the surface (mirror of the WORLD panel's
    // left-edge offset) so the central scene stays uncluttered.
    _panelAtmo = HUDPanel.new(_hud, {
      "x": w - _panelW - _panelX,
      "y": _panelY,
      "width": _panelW,
      "title": "ATMO",
      "scale": scale
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

  resize(g, w, h) {
    // Some platforms emit a resize(0, 0) on minimize; skip those
    // so we don't write a NaN aspect ratio into the projection
    // and ratchet the window down at the next valid resize.
    if (w <= 0 || h <= 0) return
    _camera.setPerspective(_fovY, w / h, 0.5, 600)
    _sky.setProjection(_fovY, w / h)
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
    _terrain.amp     = _knobs["terrainAmp"]["v"]
    _waterY         = _knobs["waterY"]["v"]
    var ampScale    = _terrain.amp / _terrain.ampBase
    var terrainModel = Mat4.scale(1, ampScale, 1)
    var waterModel  = Mat4.translation(0, _waterY, 0)

    // ── Shadow pre-pass ─────────────────────────────────────────
    // Soft directional shadows. End the framework's main pass
    // (which it just opened but we haven't drawn into yet), run a
    // depth-only pass from the sun's POV into the shadow map,
    // then reopen the main pass with `loadOp: "load"` to pick up
    // the cleared color/depth the framework's pass already wrote.
    // Terrain is non-instanced; foliage buckets use the
    // instanced shadow path with the same instance buffers the
    // main PBR pass already populated.
    pass.end
    // Prep foliage matrices BEFORE the shadow pass so both the
    // shadow draw and the main draw consume the same uploaded
    // instance buffers (FoliageScene.uploadIfDirty_ runs once and
    // flips its dirty bit, so the second consumer is free).
    if (_flags["showFoliage"]) {
      _foliage.setWaterY(_waterY)
      _foliage.update(ampScale)
    }
    // Shadow-box centre is FIXED at the island origin instead of
    // tracking the camera target. A moving centre quantises the
    // shadow-map texels against the camera's pan, making every
    // shadow edge shimmer as the user drags the view; pinning it
    // to (0,0,0) gives stable edges for a static scene. The
    // shadow extent (90 m half-width) is sized to cover the whole
    // 152 m island from origin.
    _renderer.beginShadowPass(g.encoder, _sun["dir"], Vec3.zero)
    _renderer.drawShadow(_terrain.mesh, terrainModel)
    if (_flags["showFoliage"]) _foliage.drawShadow(_renderer)
    _renderer.endShadowPass
    pass = g.encoder.beginRenderPass({
      "colorAttachments": [{
        "view":     g.colorView,
        "loadOp":   "load",
        "storeOp":  "store"
      }],
      "depthStencilAttachment": {
        "view":          g.depthView,
        "depthLoadOp":   "load",
        "depthStoreOp":  "store"
      }
    })
    g.pass = pass

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

    // Pick up HUD-driven FOV + cloud edits before the camera and
    // sky UBOs upload this frame. Camera projection rebuilds are
    // cheap (one Mat4); sky cloud coverage is a single uniform.
    if (_knobs["fov"]["v"] != _fovY) {
      _fovY = _knobs["fov"]["v"]
      _camera.setPerspective(_fovY, g.width / g.height, 0.5, 600)
      _sky.setProjection(_fovY, g.width / g.height)
    }
    _sky.setClouds(_knobs["cloudCover"]["v"], 320.0, 1.4, [1.00, 0.96, 0.88])

    // Sky first — clip.z=1 + depthCompare="less-equal" means every
    // terrain/foliage fragment overwrites the sky in pass 1, so the
    // dome only survives where no geometry covers it (horizon).
    _sky.beginFrame(pass, _camera, g.elapsed)
    _sky.draw()
    _sky.endFrame()

    // Terrain through Renderer3D's PBR pipeline.
    _renderer.beginFrame(pass, _camera)
    Sun.applyTo(_renderer, _sun)
    // Wind: base direction + base strength + gust modulation. Gust
    // adds extra punch on top of the base; both feed the foliage
    // sway in the vertex shader.
    var windStr = _windOpts["baseStrength"] * (1 + _windOpts["gust"] * 0.7)
    _renderer.setWind(_windOpts["baseX"], _windOpts["baseZ"], windStr)
    _renderer.setWindTime(g.elapsed)
    _renderer.draw(_terrain.mesh, _terrain.mat, terrainModel)

    // Foliage: matrices are precomputed inside `FoliageScene` and
    // only rebuilt when a density knob or the terrain amp slider
    // changes. `update(ampScale)` decides; `draw(renderer)` issues
    // the per-bucket instanced draws (≤ 5 buffer uploads + ~10
    // draws per frame).
    // Foliage matrices were already updated + uploaded in the
    // shadow pre-pass earlier in this frame; main-pass draw just
    // rebinds the prepared instance buffers and issues PBR draws.
    if (_flags["showFoliage"]) _foliage.draw(_renderer)
    var fc = _foliage.counts
    _visibleCount = fc[0] + fc[1] + fc[2] + fc[3] + fc[4]
    _culledCount  = 0

    // Rain — picks up live HUD edits, then renders the curtain.
    // Spawn at the camera's LOOK target (where the user is looking
    // by definition), not the eye — when the camera looks down at
    // the island, the eye-centred column sits above the frustum
    // and the user sees nothing. Anchoring on `_camera.target`
    // puts the column squarely where the player's looking.
    _rain.isPlaying    = _knobs["rainOn"]["v"]
    _rain.emissionRate = _knobs["rainRate"]["v"]
    // Wind drifts the rain horizontally — same baseX/baseZ ×
    // strength the foliage sway and water flow sample. The
    // foliage-wind sliders now visibly tilt the curtain too.
    var windStrR = _windOpts["baseStrength"] * (1 + _windOpts["gust"] * 0.7)
    var windVxR = _windOpts["baseX"] * windStrR
    var windVzR = _windOpts["baseZ"] * windStrR
    _rain.setWindDrift(windVxR, windVzR)
    // Streaks slant toward the wind direction instead of moving
    // bodily sideways: rotate every billboard around the
    // camera-forward axis by atan2(|wind|, fallSpeed), so the
    // streak's long axis aligns with the velocity vector.
    var windMag = (windVxR * windVxR + windVzR * windVzR).sqrt
    _rain.rotation = (-windMag).atan(14)
    // Screen-space width: streaks closer than 25m to the eye
    // shrink proportionally so they read as thin lines, not blobs.
    _rain.setScreenSpaceWidth(25)
    _rain.setCameraEye(eye.x, eye.y, eye.z)
    // Spawn 20m above a point biased toward the camera's look
    // direction. Pure-target anchoring breaks close-camera shots —
    // streaks all fall around the look-at point and never appear
    // in the foreground. Sliding the column 30%% of the way back
    // toward the eye keeps the curtain visible whether the camera
    // is in overview (distance 90) or zoomed in tight (distance 8).
    var t = _camera.target
    var rainX = eye.x + (t.x - eye.x) * 0.35
    var rainZ = eye.z + (t.z - eye.z) * 0.35
    _rain.setPosition(rainX, t.y + 20, rainZ)
    _rain.draw(_renderer)
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
    _water.setColors([0.22, 0.58, 0.65, _knobs["waterAlpha"]["v"]], [0.60, 0.82, 0.92], 3.5)
    _water.setFoam([0.95, 0.98, 1.0], _knobs["foamThresh"]["v"])
    _water.setFlow(_windOpts["baseX"], _windOpts["baseZ"], _windOpts["baseStrength"] * 0.08)
    // Rebind shore depth to the live pass-1 attachment. `g.depthView`
    // is only the framework's scene-depth INSIDE the user draw block;
    // outside it (resize callback) it points at the swap-chain depth
    // which pass 1 never wrote under PostFX, making `beneath` collapse
    // to zero and shore-foam fire across the entire surface.
    if (_lastShoreDepthView_ != g.depthView) {
      _water.setShore(g.depthView, 0.5, 600, _shoreBand)
      _lastShoreDepthView_ = g.depthView
    }
    _water.setShoreBand(_knobs["shoreBand"]["v"])
    // Pick up HUD slider edits before the per-frame UBO upload.
    // Guard `end > start + ε` so the FS's `1 / (end-start)` term
    // doesn't blow up if the user drags the two sliders past each
    // other.
    _fog.start   = _knobs["fogStart"]["v"]
    var fogEnd   = _knobs["fogEnd"]["v"]
    if (fogEnd < _fog.start + 1.0) fogEnd = _fog.start + 1.0
    _fog.end     = fogEnd
    _fog.density = _knobs["fogDensity"]["v"]
    _fog.curve   = _knobs["fogFlags"]["expCurve"] ? 1 : 0
    _water.setFog(_fog)
    // Rain → water ripples. Both the density (rings per square
    // metre firing) AND the strength (per-ring amplitude) scale
    // with the rain-rate slider — so a light shower shows a sparse
    // soft spatter and a downpour fills the surface with sharper
    // rings. Off-state passes strength 0 and the shader skips the
    // whole ripple branch.
    var rippleStr = 0.0
    var rippleDens = 0.0
    if (_knobs["rainOn"]["v"]) {
      var rateNorm = _knobs["rainRate"]["v"] / 1500.0
      if (rateNorm > 1) rateNorm = 1
      if (rateNorm < 0) rateNorm = 0
      rippleStr  = 0.05 + rateNorm * 0.55
      rippleDens = 0.08 + rateNorm * 0.55
    }
    _water.setRippleStrength(rippleStr)
    _water.setRippleDensity(rippleDens)
    _water.beginFrame(pass, _camera, _waterTime)
    _water.draw(_waterMesh, waterModel)
    _water.endFrame()

    // ── HUD overlay ────────────────────────────────────────────
    _hudRenderer.beginFrame(_hudCamera)
    _hudRenderer.beginPass(g.pass)
    _hud.beginFrame(g, _hudRenderer)
    _panel.beginFrame()
    _panel.text("FPS", _fps.round)
    var hc = _foliage.counts
    var ph = _foliage.paletteHist
    _panel.text("grass",   "%(hc[0]) / %(ph[0])")
    _panel.text("bush c",  "%(hc[1]) / %(ph[1])")
    _panel.text("bush f",  "%(hc[2]) / %(ph[2])")
    _panel.text("tree s",  "%(hc[3]) / %(ph[3])")
    _panel.text("tree l",  "%(hc[4]) / %(ph[4])")
    _panel.divider()
    // Amp ceiling sized against the terrain's nearshore relief —
    // anything beyond ~0.3 m crests above the sand band and reads
    // as the ocean flooding the island. Freq up to 1.5/m gives
    // chop; below 0.3/m reads as long swell.
    _panel.slider("water amp",  _waveOpts, "amplitude", 0.0, 0.3)
    _panel.slider("water freq", _waveOpts, "scale",     0.1, 1.5)
    _panel.slider("water time", _waveOpts, "timeScale", 0.0, 2.0)
    _panel.slider("alpha",      _knobs["waterAlpha"],   "v",  0.0, 1.0)
    // Foam threshold is opt-in: at 1.0 the crest smoothstep never
    // fires (clean water + just specular highlights). Drop the
    // slider toward 0.4 only when you want chop foam on the open
    // surface.
    _panel.slider("foam",       _knobs["foamThresh"],   "v",  0.4, 1.0)
    _panel.slider("shore band", _knobs["shoreBand"],    "v",  0.2, 5.0)
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
    _panel.slider("terrain amp", _knobs["terrainAmp"], "v", 2.0, 18.0)
    _panel.slider("water y",     _knobs["waterY"],     "v", -6.0, 4.0)
    _panel.divider()
    _panel.toggle("foliage", _flags, "showFoliage")
    _panel.slider("grass",   _knobs["grassDens"], "v", 0.0, 1.0)
    _panel.slider("foliage", _knobs["otherDens"], "v", 0.0, 1.0)
    _panel.slider("scatter", _knobs["scatter"],      "v", 0.0, 1.0)

    // Atmospheric / camera knobs live in their own panel so the
    // main WORLD strip doesn't overflow the window. FOV is a
    // slider so the change is reversible by drag. Fog start/end
    // define the linear false-horizon band; toggle `fog exp²` for
    // an exponential haze using the density slider instead.
    _panelAtmo.beginFrame()
    _panelAtmo.slider("fov",       _knobs["fov"],        "v", 30.0, 90.0)
    _panelAtmo.slider("fog start", _knobs["fogStart"],   "v",  0.0, 300.0)
    _panelAtmo.slider("fog end",   _knobs["fogEnd"],     "v", 20.0, 400.0)
    _panelAtmo.slider("fog dens",  _knobs["fogDensity"], "v",  0.0, 0.08)
    _panelAtmo.toggle("fog exp²",  _knobs["fogFlags"], "expCurve")
    _panelAtmo.slider("clouds",    _knobs["cloudCover"], "v",  0.0, 1.0)
    _panelAtmo.toggle("rain",      _knobs["rainOn"],     "v")
    _panelAtmo.slider("rain rate", _knobs["rainRate"],   "v",  0.0, 1500.0)
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
      Sun.applyTo(_renderer, _sun)
      _renderer.draw(_terrain.mesh, _terrain.mat, terrainModel)
      if (_flags["showFoliage"]) _foliage.draw(_renderer)
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
    _sky.destroy
    _water.destroy
    _foliage.destroy
    _renderer.destroy
  }
}

Game.run(ProceduralWorld)
