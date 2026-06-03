// animation-showcase — load a glTF asset, parse its animation
// channels, and play the embedded "Start_Liftoff" clip with TRS
// keyframes driving per-node `Transform` components. ECS handles
// hierarchy + rendering; the demo's per-frame work is just the
// sample-and-write loop over animation channels.

import "@hatch:game"   for Game, Transform, GlobalTransform, MeshRenderer
import "@hatch:game"   for TransformPropagation, SceneRenderer3D
import "@hatch:game"   for AmbientLight, DirectionalLight, SpotLight, PostFX
import "@hatch:ecs"    for World
import "@hatch:gpu"    for Renderer3D, Camera3D, Mesh, Material
import "@hatch:math"   for Vec3, Vec4, Quat
import "@hatch:gltf"   for Gltf
import "@hatch:assets" for Assets
import "@hatch:postfx" for Bloom, Vignette

class AnimShowcase is Game {
  construct new() {}

  config { {
    "title":      "Animation Showcase — Buster Drone",
    "width":      1280,
    "height":     720,
    // Soft cool dark-grey backdrop — matches the colour the
    // Boden floor fades into so the alpha-blended disc edge
    // dissolves seamlessly rather than reading as a circle on a
    // different colour.
    "clearColor": [0.21, 0.22, 0.26, 1.0],
    "depth":      true
  } }

  setup(g) {
    _renderer = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)
    // Blinc's reference renderer's "procedural environment" is
    // uniform 0.75 linear grey across every face + mip of its
    // IBL cubemap — flat studio grey, NOT a sky gradient. This
    // is the magic that lifts metal panels without tinting them
    // (dark materials × ambient = pitch black without IBL fill;
    // grey × baseColor naturally attenuates per-material so
    // brights brighten without saturating to ambient colour).
    // Our 3-band gradient becomes flat by setting all three to
    // the same value.
    // 0.75 = Blinc's value, but without their HDR-end-to-end
    // pipeline the bright IBL fill collapses post-tonemap so the
    // shadow contrast disappears. 0.30 keeps the IBL's metal-
    // reflection effect while letting the directional sun own
    // the dynamic range — shadows then read as a real drop.
    var grey = Vec3.new(0.30, 0.30, 0.32)
    _renderer.setEnvironment(grey, grey, grey)
    // Post-FX chain — bloom on the bright body highlights + a
    // gentle vignette darkens the corners so the bright pool of
    // light on the floor reads as a focal point. Order: bloom first
    // (uses HDR-ish input the PBR shader emits), vignette last for
    // the framing.
    g.postFX = PostFX.new(g)
    // Our PBR shader tonemaps to LDR before PostFX sees it, so
    // bloom thresholds > 1.0 catch nothing (Blinc keeps the
    // pipeline HDR end-to-end, no equivalent). Threshold 0.85
    // catches the near-saturated PBR output on metal highlights
    // and the green emissive strips; intensity 0.3 keeps the
    // halo subtle.
    g.postFX.add(Bloom.new({
      "threshold": 0.85,
      "knee":      0.4,
      "intensity": 0.30,
      "levels":    5
    }))
    g.postFX.add(Vignette.new({ "strength": 0.55 }))
    // Enable directional shadow mapping. The sun light below gets
    // `castsShadows = true`, so the renderer renders the scene
    // from the sun's perspective into a 2048² depth target and
    // samples it during PBR shading via PCF.
    // Extent 1200 (±600) holds the takeoff trajectory horizontally.
    // far: 5000 moves the light-camera eye to y≈2500 so the drone
    // never passes through the near plane during takeoff (was
    // clipping the rotor disc when the drone climbed above the
    // light eye's previous y≈1005 position with far=2000).
    _renderer.enableShadows({
      "size":      4096,
      "extent":    1200,
      "near":      0.5,
      "far":       5000,
      "bias":      0.002,
      // 0.0001 ≈ sub-texel; combined with the linear sampler each
      // compare bilinearly blends 4 texels so the kernel still
      // anti-aliases the silhouette naturally without the wider
      // PCF radius softening the whole shadow into mush.
      "pcfRadius": 0.0001
    })
    _camera   = Camera3D.perspective(55, g.width / g.height, 0.5, 4000)

    // The buster_drone scene authors its geometry in centimetre-
    // ish units — the model is ~150 m tall in world space. Match
    // the framing the Blinc reference uses (distance 570, target
    // raised to drone-centre Y) so the orbit camera doesn't start
    // clipping the body.
    _yaw      = 0.6
    _pitch    = 0.25
    _distance = 570
    _target   = Vec3.new(0, 47, 0)
    _lastMx   = 0
    _lastMy   = 0
    _dragging = false
    refreshCamera_()

    // World + glTF load. `Assets.open(dir)` rooted at the demo
    // directory finds `buster_drone/scene.gltf` + sibling .bin +
    // textures. The loader parses + uploads in one pass.
    _world = World.new()
    var db = Assets.open("assets")
    _scene = Gltf.fromAssetsDir(g.device, db, "buster_drone/scene.gltf")
    _scene.spawnInto(_world)

    // Boost emissive on every gpu material whose source had an
    // emissive map. The asset's glTF emissiveFactor is (1, 1, 1)
    // and the renderer's lighting path is analytic-only — without
    // a punch over 1.0 the textured emission lands at LDR-range
    // values that ACES tonemap compresses to near-flat. The
    // gpu-side `Material` is mutable; walk through the parsed
    // meshes → primitives → `material` references and bump.
    // Per-material emissive boost. Body's emissive map carries the
    // green LED strips on the rotor pads; without a multiplier
    // they sit at LDR values that ACES compresses to near-flat.
    var boosted = 0
    for (gltfMesh in _scene.meshes) {
      for (prim in gltfMesh.primitives) {
        var mat = prim.material
        if (mat == null) continue
        if (mat.emissiveTexture != null) {
          mat.emissiveColor = Vec4.new(4.0, 4.0, 4.0, 1.0)
          boosted = boosted + 1
        }
      }
    }
    System.print("emissive boost applied to %(boosted) primitive material(s)")

    // Force the body's BLEND→opaque (the asset's mat 1 ships as
    // BLEND incorrectly; the body shell should be solid). Leave
    // the Boden floor as BLEND so its alpha-faded edge renders
    // through the alpha-blend pipeline path.
    for (gltfMesh in _scene.meshes) {
      // Boden gets to stay transparent for the soft edge.
      if (gltfMesh.name == "Scheibe_Boden_0") continue
      for (prim in gltfMesh.primitives) {
        var mat = prim.material
        if (mat == null) continue
        if (mat.alphaMode == "blend") mat.alphaMode = "opaque"
      }
    }
    // Brighten the Boden floor so the cast shadow has contrast
    // to register against. Texture is dark stone (~RGB 110);
    // multiplying by 4 reads as lit polished concrete and the
    // shadow shows as a clear darker patch.
    for (gltfMesh in _scene.meshes) {
      if (gltfMesh.name != "Scheibe_Boden_0") continue
      for (prim in gltfMesh.primitives) {
        if (prim.material == null) continue
        prim.material.albedoColor    = Vec4.new(2.2, 2.2, 2.3, 1.0)
        prim.material.roughnessFactor = 0.9
        prim.material.metallicFactor  = 0.0
      }
    }

    // Red eye stamp — the FBX→glTF converter dropped the UV link
    // for body_emissive.png's red pixel, so we stamp the eye / lens
    // subtree materials directly. Matches the technique the sibling
    // Blinc demo uses on the same asset. Walks the children of
    // `Eye_Pupil` / `Eye_Controller` / any node whose name contains
    // `IEye` or `ILens`, collects every mesh in that subtree, and
    // forces its primitive materials' emissiveColor to bright red.
    var lensRoots = []
    var ni = 0
    while (ni < _scene.nodes.count) {
      var nm = _scene.nodes[ni].name
      if (nm == "Eye_Pupil" || nm == "Eye_Controller" ||
          nm.contains("IEye") || nm.contains("ILens")) {
        lensRoots.add(ni)
      }
      ni = ni + 1
    }
    var lensMeshIds = {}
    while (lensRoots.count > 0) {
      var idx = lensRoots.removeAt(lensRoots.count - 1)
      var node = _scene.nodes[idx]
      if (node.meshIndex != null) lensMeshIds[node.meshIndex] = true
      for (childIdx in node.children) lensRoots.add(childIdx)
    }
    var lensCount = 0
    for (meshIdx in lensMeshIds.keys) {
      for (prim in _scene.meshes[meshIdx].primitives) {
        var mat = prim.material
        if (mat == null) continue
        mat.emissiveColor = Vec4.new(12.0, 0.0, 0.0, 1.0)
        // Body material ships with alphaMode=BLEND. Our PBR pipeline
        // doesn't have blend state set, so transparent fragments
        // write (rgb, 0) and are overwritten by whatever draws on
        // top. Force the stamped lens primitives back to opaque so
        // the red emissive wins the depth race against the body
        // shell's "port hole" fragments behind it.
        mat.alphaMode    = "opaque"
        mat.albedoColor  = Vec4.new(0.05, 0.0, 0.0, 1.0)
        lensCount = lensCount + 1
      }
    }
    System.print("red eye stamp applied to %(lensCount) lens primitive material(s)")

    // Studio three-point. Dim cool ambient + a strong overhead
    // key (casts the contact shadow on the Boden) + a softer
    // back-fill so the dark side of the drone reads as material
    // rather than silhouette.
    // Mirror Blinc's reference rig: ONE directional light, white,
    // intensity 6, direction (-0.4, -1, -0.3), no shadow map.
    // The "shadow" feel in their reference is emergent from
    // HDR + bloom + the light angle making the drone's underside
    // dark; we keep our shadow map enabled for the floor contact
    // shadow that pure-directional Lambert can't produce.
    // Ambient stays low — IBL handles the fill so the analytic
    // ambient doesn't double-up and wash shadows out.
    var amb = _world.spawn()
    _world.attach(amb, AmbientLight.new(Vec3.new(0.15, 0.16, 0.22), 0.4))

    var sun = _world.spawn()
    var sunLight = DirectionalLight.new(Vec3.new(1.0, 1.0, 1.0), 6.0)
    sunLight.castsShadows = true   // we need this for the floor contact shadow
    _world.attach(sun, sunLight)
    // Direction (-0.4, -1, -0.3) — same as Blinc. Build a Transform
    // rotation that takes the renderer's LIGHT_FORWARD_ axis
    // (0, 0, -1) into that direction. Atan2 in two axes:
    //   yaw   = atan2(-0.4, -0.3) → rotate around Y first
    //   pitch = atan2(-1, sqrt(.4² + .3²)) → then around X
    // Quick build: rotate around X by ~atan2(1, 0.3) ≈ 1.279,
    // then around Y by ~atan2(0.4, 0.3) ≈ 0.927.
    _world.attach(sun, Transform.new(
      Vec3.new(0, 0, 0),
      Quat.fromAxisAngle(Vec3.new(1, 0, 0), -1.279),
      Vec3.one))

    // Pick the first animation. Buster drone has one, named
    // "Start_Liftoff" — 100 channels driving each part of the
    // drone's body / pads / arms.
    if (_scene.animations.count == 0) {
      Fiber.abort("buster_drone has no animations — wrong asset?")
    }
    _anim = _scene.animations[0]
    _animTime = 0
    _paused = false
    _speed  = 1.0
    System.print("Loaded animation '%(_anim.name)', %(_anim.duration)s, %(_anim.channels.count) channels")
  }

  refreshCamera_() {
    var cp = _pitch.cos
    var sp = _pitch.sin
    var cy = _yaw.cos
    var sy = _yaw.sin
    var ex = _target.x + _distance * cp * sy
    var ey = _target.y + _distance * sp
    var ez = _target.z + _distance * cp * cy
    _camera.lookAt(Vec3.new(ex, ey, ez), _target, Vec3.unitY)
  }

  // Apply every channel of `_anim` to its target entity's
  // Transform. Time loops over the clip duration so the lift-off
  // replays continuously.
  applyAnimation_() {
    var map = _scene.nodeEntityMap
    if (map == null) return
    var dur = _anim.duration
    var tLooped = dur > 0 ? (_animTime - dur * (_animTime / dur).floor) : 0
    for (ch in _anim.channels) {
      var entity = map[ch.nodeIndex]
      if (entity == null) continue
      if (!_world.has(entity, Transform)) continue
      var v = ch.sample(tLooped)
      var transform = _world.get(entity, Transform)
      if (ch.path == "translation") {
        transform.position = Vec3.new(v[0], v[1], v[2])
      } else if (ch.path == "rotation") {
        // glTF stores quaternions as (x, y, z, w); Quat is (w, x, y, z).
        // LINEAR-lerped quat components don't preserve unit length;
        // the resulting Mat4 picks up a non-uniform scale that
        // shows as z-fighting on stacked geometry. Normalise.
        transform.rotation = Quat.new(v[3], v[0], v[1], v[2]).normalized
      } else if (ch.path == "scale") {
        transform.scale = Vec3.new(v[0], v[1], v[2])
      }
    }
  }

  update(g) {
    var mx = g.input.mouseX
    var my = g.input.mouseY
    if (g.input.mouseDown("left")) {
      if (_dragging) {
        _yaw   = _yaw   - (mx - _lastMx) * 0.005
        _pitch = _pitch - (my - _lastMy) * 0.005
        if (_pitch >  1.4) _pitch =  1.4
        if (_pitch < -1.4) _pitch = -1.4
      }
      _dragging = true
    } else {
      _dragging = false
    }
    _lastMx = mx
    _lastMy = my
    if (g.input.scrollY != 0) {
      _distance = _distance - g.input.scrollY * 20
      if (_distance < 80)   _distance = 80
      if (_distance > 2000) _distance = 2000
    }
    refreshCamera_()

    if (g.input.justPressed("Space")) _paused = !_paused
    if (g.input.justPressed("R"))     _animTime = 0
    if (g.input.justPressed("Escape")) g.requestQuit

    if (!_paused) _animTime = _animTime + g.dt * _speed
    applyAnimation_()
  }

  draw(g) {
    // Propagate every Transform we just wrote into GlobalTransform
    // so the renderer sees the updated world matrices.
    TransformPropagation.run(_world)
    SceneRenderer3D.runShadows(_world, _renderer, g.encoder, _target)
    SceneRenderer3D.run(_world, _camera, _renderer, g.pass)
  }
}

Game.run(AnimShowcase)
