// skeletal-animation-demo — load `the_strangler` (CC-BY-4.0 by
// Jungle Jim) and drive its 102-joint skinned rig through the GPU
// skinning path.
//
// Scene flow follows the canonical hatch loading pattern:
//
//   splash ──► loading ──► ready ──► playing
//
// `AssetLoader` queues each gltf phase as a separate frame-amortised
// entry (one buffer read, one PNG decode + GPU upload per image,
// one mesh upload, then a finalize step). `StateChart` orchestrates
// the high-level transitions; `HUD` renders the splash text and
// progress bar.
//
// Per-frame (playing state):
//   - Advance _animTime modulo clip duration; `GltfAnimation.applyTo`
//     writes T/R/S into every animated joint node's Transform.
//   - `TransformPropagation.run` composes world matrices.
//   - For each skin, palette[k] = joint_world * IBM_k. Upload.
//   - `Renderer3D.drawSkinned` per skinned MeshRenderer, `draw` per
//     static one.

import "@hatch:game"   for Game, Transform, GlobalTransform, MeshRenderer, TransformPropagation, AmbientLight, DirectionalLight
import "@hatch:ecs"    for World
import "@hatch:gpu"    for Renderer3D, Renderer2D, Camera3D, Camera2D, Mesh, Material, SkinPalette
import "@hatch:math"   for Vec3, Vec4, Mat4, Quat
import "@hatch:gltf"   for Gltf
import "@hatch:assets" for Assets, AssetLoader
import "@hatch:fsm"    for StateChart
import "@hatch:hud"    for HUD

class SkeletalDemo is Game {
  static DESIGN_W { 960 }
  static DESIGN_H { 720 }

  construct new() {}

  config { {
    "title":      "Skeletal Animation Demo — the_strangler",
    "width":      SkeletalDemo.DESIGN_W,
    "height":     SkeletalDemo.DESIGN_H,
    "clearColor": [0.18, 0.20, 0.24, 1.0],
    "depth":      true
  } }

  setup(g) {
    _renderer  = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)
    _renderer.setAmbient(Vec3.new(0.55, 0.60, 0.70), 0.8)
    _camera    = Camera3D.perspective(45, g.width / g.height, 0.1, 20000)
    // 3-arg ctor: builds depth-compatible pipelines so the 2D HUD
    // can co-exist with Renderer3D's depth-attached pass without
    // `Incompatible depth-stencil attachment` validation errors.
    _renderer2 = Renderer2D.new(g.device, g.surfaceFormat, g.depthFormat)
    _camera2   = Camera2D.contain(SkeletalDemo.DESIGN_W, SkeletalDemo.DESIGN_H, g.width, g.height)
    _hud       = HUD.new(g)
    _world     = World.new()

    // Splash hangs for `_splashLength` seconds so the title's
    // legible, then transitions into loading. AssetLoader's
    // `onComplete` advances loading → ready; a mouse click advances
    // ready → playing.
    _chart = StateChart.build {|c|
      c.id("flow")
      c.initial("splash")
      c.state("splash")  {|s| s.on("ready",   "loading") }
      c.state("loading") {|s|
        s.on("loaded",    "ready")
        s.on("loadError", "error")
      }
      c.state("ready")   {|s| s.on("start", "playing") }
      c.state("playing") {|s|}
      c.state("error")   {|s|}
    }
    _chart.start()

    _splashTimer  = 0
    _splashLength = 1.2

    // Streaming gltf load — one queue entry per buffer read, image
    // read, image upload, mesh upload, plus structural assemble and
    // finalize bookends. The progress bar reflects actual work, not
    // a fake spinner; the window stays responsive between entries.
    _db          = Assets.open("assets")
    _gltfState   = Gltf.openDir(_db, "the_strangler/scene.gltf")
    _loader      = AssetLoader.new()
    var device   = g.device
    var state    = _gltfState
    var db       = _db

    var i = 0
    while (i < state["bufferCount"]) {
      var idx = i
      _loader.queue("buf_%(idx)", Fn.new { Gltf.loadBuffer(state, db, idx) })
      i = i + 1
    }
    i = 0
    while (i < state["imageCount"]) {
      var idx = i
      _loader.queue("img_bytes_%(idx)", Fn.new { Gltf.loadImage(state, db, idx) })
      i = i + 1
    }
    _loader.queue("assemble", Fn.new { Gltf.assemble(state) })
    i = 0
    while (i < state["imageCount"]) {
      var idx = i
      _loader.queue("img_upload_%(idx)", Fn.new { Gltf.uploadImageAt(state, device, idx) })
      i = i + 1
    }
    // Mesh count is only known after `assemble`. We can't size the
    // queue against it until then, so a single bulk "meshes" entry
    // covers them — meshes are cheap (VBO/IBO upload, no decode).
    _loader.queue("meshes", Fn.new {
      var scene = state["scene"]
      var mi = 0
      while (mi < scene.meshes.count) {
        Gltf.uploadMeshAt(state, device, mi)
        mi = mi + 1
      }
    })
    _loader.queue("finalize", Fn.new { Gltf.finishUpload(state) })

    var self = this
    _loader.onProgress(Fn.new {|f, d, t|
      self.onLoadProgress_(f, d, t)
    })
    _loader.onError(Fn.new {|name, err|
      System.print("[load] '%(name)' failed: %(err)")
      _chart.send("loadError")
    })
    _loader.onComplete(Fn.new {|loaded|
      self.onLoadComplete_(g)
    })

    _loadFraction = 0
    _loadDone     = 0
    _loadTotal    = 0
    _loadStage    = ""

    // Sun + ambient fill — attached to the world so the API shape
    // mirrors regular game scenes, even though the demo dispatches
    // drawSkinned manually (bypassing SceneRenderer3D). We forward
    // these explicitly in `drawScene_` after `beginFrame`.
    var sun = _world.spawn()
    _world.attach(sun, DirectionalLight.new(Vec3.new(1, 1, 1), 2.5))
    _world.attach(sun, Transform.new(
      Vec3.zero,
      Quat.fromAxisAngle(Vec3.new(1, 0, 0), -1.0),
      Vec3.one))
    var amb = _world.spawn()
    _world.attach(amb, AmbientLight.new(Vec3.new(0.25, 0.3, 0.4), 0.4))
  }

  resize(g, w, h) {
    _camera = Camera3D.perspective(45, w / h, 0.1, 20000)
    _camera2.fitContain(w, h)
  }

  onLoadProgress_(fraction, done, total) {
    _loadFraction = fraction
    _loadDone     = done
    _loadTotal    = total
  }

  // Final once-only setup that needs the assembled `GltfScene`:
  // captures it, sets up skin palettes, classifies primitives, and
  // frames the camera. Runs from `_loader.onComplete`, so the next
  // tick already has `_scene` populated and the chart sits in
  // `ready` waiting for the user's click.
  onLoadComplete_(g) {
    _scene = _gltfState["scene"]
    _scene.spawnInto(_world)

    if (_scene.animations.count == 0) Fiber.abort("the_strangler has no animations — wrong asset?")
    _anim     = _scene.animations[0]
    _animTime = 0
    _speed    = 1.0

    _skinPalettes = []
    _skinScratch  = []
    for (skin in _scene.skins) {
      _skinPalettes.add(SkinPalette.new(g.device, skin.jointCount))
      _skinScratch.add(Float32Array.new(skin.jointCount * 16))
    }

    _skinnedRecords = []
    _staticRecords  = []
    var ni = 0
    while (ni < _scene.nodes.count) {
      var node = _scene.nodes[ni]
      if (node.meshIndex != null) {
        var entity = _scene.nodeEntityMap[ni]
        if (entity != null && _world.has(entity, MeshRenderer)) {
          var mr = _world.get(entity, MeshRenderer)
          if (mr.mesh != null) {
            if (mr.mesh.jointsBuffer != null && node.skinIndex != null) {
              _skinnedRecords.add({ "entity": entity, "skin": node.skinIndex, "mr": mr })
            } else {
              _staticRecords.add({ "entity": entity, "mr": mr })
            }
          }
        }
      }
      ni = ni + 1
    }

    // Frame the camera from the bind-pose joint bounds.
    TransformPropagation.run(_world)
    var bounds = fitBounds_()
    var center = bounds[0]
    var radius = bounds[1]
    _yaw      = 0.6
    _pitch    = 0.15
    _distance = radius * 2.6
    _target   = center
    _camera.lookAt(orbitEye_(), _target, Vec3.unitY)

    System.print("[load] %(_scene.skins.count) skin(s), %(_skinnedRecords.count) skinned + %(_staticRecords.count) static records")
    _chart.send("loaded")
  }

  fitBounds_() {
    var skin = _scene.skins[0]
    var minX = 1e30
    var minY = 1e30
    var minZ = 1e30
    var maxX = -1e30
    var maxY = -1e30
    var maxZ = -1e30
    var k = 0
    while (k < skin.jointCount) {
      var e = _scene.nodeEntityMap[skin.joints[k]]
      if (e != null) {
        var gt = _world.get(e, GlobalTransform)
        if (gt != null) {
          var p = gt.matrix.transformPoint(Vec3.zero)
          if (p.x < minX) minX = p.x
          if (p.y < minY) minY = p.y
          if (p.z < minZ) minZ = p.z
          if (p.x > maxX) maxX = p.x
          if (p.y > maxY) maxY = p.y
          if (p.z > maxZ) maxZ = p.z
        }
      }
      k = k + 1
    }
    var cx = (minX + maxX) * 0.5
    var cy = (minY + maxY) * 0.5
    var cz = (minZ + maxZ) * 0.5
    var dx = maxX - minX
    var dy = maxY - minY
    var dz = maxZ - minZ
    var r = (dx * dx + dy * dy + dz * dz).sqrt * 0.5
    if (r < 0.01) r = 1.0
    return [Vec3.new(cx, cy, cz), r]
  }

  orbitEye_() {
    var cy = _yaw.cos
    var sy = _yaw.sin
    var cp = _pitch.cos
    var sp = _pitch.sin
    return Vec3.new(
      _target.x + _distance * cp * sy,
      _target.y + _distance * sp,
      _target.z + _distance * cp * cy)
  }

  update(g) {
    if      (_chart.activeStates.contains("splash"))  updateSplash_(g)
    else if (_chart.activeStates.contains("loading")) updateLoading_(g)
    else if (_chart.activeStates.contains("ready"))   updateReady_(g)
    else if (_chart.activeStates.contains("playing")) updatePlaying_(g)
  }

  draw(g) {
    // 3D scene first (behind the HUD) — only once the model is
    // loaded. The 2D HUD then draws on top of the same pass.
    if (_chart.activeStates.contains("ready") ||
        _chart.activeStates.contains("playing")) {
      drawScene_(g)
    }

    // 2D HUD overlay shared across all states.
    _renderer2.beginFrame(_camera2)
    _renderer2.beginPass(g.pass)
    _hud.beginFrame(g, _renderer2)
    if      (_chart.activeStates.contains("splash"))  drawSplashHud_(g)
    else if (_chart.activeStates.contains("loading")) drawLoadingHud_(g)
    else if (_chart.activeStates.contains("ready"))   drawReadyHud_(g)
    _hud.endFrame
    _renderer2.endPass()
    _renderer2.flush(g.pass)
  }

  // ── Splash ─────────────────────────────────────────────────────

  updateSplash_(g) {
    _splashTimer = _splashTimer + g.dt
    if (_splashTimer >= _splashLength) {
      _chart.send("ready")    // → loading
      _loader.start()
    }
  }

  drawSplashHud_(g) {
    labelCentre_("THE STRANGLER", -40, 4, [0.95, 0.95, 0.95, 1])
    labelCentre_("a skeletal-animation demo", 20, 2, [0.75, 0.78, 0.85, 0.9])
  }

  // ── Loading ────────────────────────────────────────────────────

  updateLoading_(g) {
    // One queue entry per frame keeps the window-event pump alive
    // between PNG decodes — each individual decode still blocks the
    // single frame it runs on, but the UI animates between entries.
    _loader.update(g.dt)
  }

  drawLoadingHud_(g) {
    labelCentre_("LOADING", -50, 3, [1, 1, 1, 1])

    var barW = 540
    var barH = 18
    var barX = (SkeletalDemo.DESIGN_W - barW) / 2
    var barY = SkeletalDemo.DESIGN_H / 2 - barH / 2
    _hud.rect(barX, barY, barW, barH, [0.18, 0.18, 0.22, 0.9])
    _hud.rect(barX + 2, barY + 2, ((barW - 4) * _loadFraction).floor, barH - 4, [0.4, 0.85, 0.5, 1])

    var pct = (_loadFraction * 100).floor
    labelCentre_("%(pct)%  (%(_loadDone) / %(_loadTotal))", 36, 2, [0.85, 0.85, 0.85, 1])
    labelCentre_("decoding textures takes a few seconds each", 70, 1, [0.6, 0.65, 0.75, 0.85])
  }

  // ── Ready ──────────────────────────────────────────────────────

  updateReady_(g) {
    if (g.input.mouseJustPressed("left") || g.input.justPressed("Space") || g.input.justPressed("Return")) {
      _chart.send("start")
    }
  }

  drawReadyHud_(g) {
    labelCentre_("READY", -40, 4, [1, 1, 1, 1])
    labelCentre_("click / space to begin", 20, 2, [0.85, 0.85, 0.85, 1])
  }

  // ── Playing ────────────────────────────────────────────────────

  updatePlaying_(g) {
    _animTime = _animTime + g.dt * _speed
    var dur = _anim.duration
    var tLooped = dur > 0 ? (_animTime - dur * (_animTime / dur).floor) : 0
    _anim.applyTo(_scene, _world, tLooped)

    if (g.input.mouseDown("left")) {
      if (_lastMx != null) {
        _yaw   = _yaw   - (g.input.mouseX - _lastMx) * 0.005
        _pitch = _pitch - (g.input.mouseY - _lastMy) * 0.005
        if (_pitch >  1.4) _pitch =  1.4
        if (_pitch < -1.4) _pitch = -1.4
      }
      _lastMx = g.input.mouseX
      _lastMy = g.input.mouseY
    } else {
      _lastMx = null
      _lastMy = null
    }
    if (g.input.scrollY != 0) {
      _distance = _distance - g.input.scrollY * 0.2 * _distance
      if (_distance < 0.5)   _distance = 0.5
      if (_distance > 5000)  _distance = 5000
    }
    _camera.lookAt(orbitEye_(), _target, Vec3.unitY)
  }

  drawScene_(g) {
    TransformPropagation.run(_world)
    composeSkinPalettes_()

    _renderer.beginFrame(g.pass, _camera)
    // Push the world's DirectionalLight + AmbientLight into the
    // per-frame UBO. SceneRenderer3D would do this automatically,
    // but the demo opts out of it to dispatch drawSkinned manually.
    _renderer.addDirectional(
      Vec3.new(0.4, -0.8, -0.3),
      Vec3.new(1, 1, 1), 2.5, false)
    _renderer.addDirectional(
      Vec3.new(-0.5, -0.3, 0.4),
      Vec3.new(0.9, 0.95, 1.0), 1.0, false)

    for (rec in _skinnedRecords) {
      var entity = rec["entity"]
      var mr = rec["mr"]
      var gt = _world.get(entity, GlobalTransform)
      var model = gt == null ? Mat4.identity : gt.matrix
      _renderer.drawSkinned(mr.mesh, mr.material, _skinPalettes[rec["skin"]], model)
    }
    for (rec in _staticRecords) {
      var entity = rec["entity"]
      var mr = rec["mr"]
      var gt = _world.get(entity, GlobalTransform)
      var model = gt == null ? Mat4.identity : gt.matrix
      _renderer.draw(mr.mesh, mr.material, model)
    }
    _renderer.endFrame()
  }

  // Compose palette[k] = jointWorld_k * inverseBindMatrix_k.
  composeSkinPalettes_() {
    var si = 0
    while (si < _scene.skins.count) {
      var skin = _scene.skins[si]
      var scratch = _skinScratch[si]
      var ibm = skin.inverseBindMatrices
      var k = 0
      while (k < skin.jointCount) {
        var jointEntity = _scene.nodeEntityMap[skin.joints[k]]
        var jointWorld = Mat4.identity
        if (jointEntity != null) {
          var gt = _world.get(jointEntity, GlobalTransform)
          if (gt != null) jointWorld = gt.matrix
        }
        var ibmRow = SkeletalDemo.colMajorToRowMajor_(ibm, k * 16)
        var skinMat = jointWorld * ibmRow
        SkeletalDemo.packMat4ColMajor_(scratch, k * 16, skinMat)
        k = k + 1
      }
      _skinPalettes[si].update(scratch)
      si = si + 1
    }
  }

  static colMajorToRowMajor_(floats, offset) {
    var m = Mat4.new()
    var c = 0
    while (c < 4) {
      var r = 0
      while (r < 4) {
        m.set(r, c, floats[offset + c * 4 + r])
        r = r + 1
      }
      c = c + 1
    }
    return m
  }

  static packMat4ColMajor_(out, offset, m) {
    var d = m.data
    var c = 0
    while (c < 4) {
      var r = 0
      while (r < 4) {
        out[offset + c * 4 + r] = d[r * 4 + c]
        r = r + 1
      }
      c = c + 1
    }
  }

  // ── HUD helpers ────────────────────────────────────────────────

  labelCentre_(text, yOffset, scale, color) {
    var size = HUD.measure(text, scale)
    var x = ((SkeletalDemo.DESIGN_W - size[0]) / 2).floor
    var y = (SkeletalDemo.DESIGN_H / 2 + yOffset - size[1] / 2).floor
    _hud.label(text, x, y, scale, color)
  }
}

Game.run(SkeletalDemo)
