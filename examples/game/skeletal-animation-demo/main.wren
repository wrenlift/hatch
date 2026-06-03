// skeletal-animation-demo — load `the_strangler` (CC-BY-4.0 by
// Jungle Jim) and drive its 102-joint skinned rig through the
// new GPU skinning path.
//
// Pipeline:
//   1. Gltf.fromAssetsDir parses the .gltf + .bin and uploads
//      every texture / mesh. Primitives that carry JOINTS_0 +
//      WEIGHTS_0 get a skinned Mesh via Mesh.fromArraysSkinned;
//      everything else stays static.
//   2. spawnInto materialises nodes as ECS entities with
//      Transforms; primitives become MeshRenderers. Joint nodes
//      become Transform-carrying entities so the scene-graph pass
//      can compose their world matrices.
//   3. One SkinPalette storage buffer per skin (102 mat4s for
//      the_strangler).
//   4. Per frame:
//      - Advance _animTime modulo the clip duration.
//      - GltfAnimation.applyTo writes T/R/S into every animated
//        joint node's Transform.
//      - TransformPropagation.run composes world matrices.
//      - For each skin, compose palette[k] = joint_world * IBM_k
//        in the appropriate column-major layout, upload.
//      - drawSkinned per skinned MeshRenderer, plain draw per
//        static one.

import "@hatch:game"   for Game, Transform, GlobalTransform, MeshRenderer, TransformPropagation, AmbientLight, DirectionalLight
import "@hatch:ecs"    for World
import "@hatch:gpu"    for Renderer3D, Camera3D, Mesh, Material, SkinPalette
import "@hatch:math"   for Vec3, Vec4, Mat4, Quat
import "@hatch:gltf"   for Gltf
import "@hatch:assets" for Assets

class SkeletalDemo is Game {
  config { {
    "title":      "Skeletal Animation Demo — the_strangler",
    "width":      960,
    "height":     720,
    "clearColor": [0.18, 0.20, 0.24, 1.0],
    "depth":      true
  } }

  setup(g) {
    _renderer = Renderer3D.new(g.device, g.surfaceFormat, g.depthFormat)
    _renderer.setAmbient(Vec3.new(0.55, 0.60, 0.70), 0.8)
    _camera = Camera3D.perspective(45, g.width / g.height, 0.1, 20000)

    System.print("loading the_strangler (this can take ~40s on first run — PNG decode + GPU upload)…")
    _world = World.new()
    var db = Assets.open("assets")
    _scene = Gltf.fromAssetsDir(g.device, db, "the_strangler/scene.gltf")
    _scene.spawnInto(_world)
    System.print("loaded: nodes=%(_scene.nodes.count) meshes=%(_scene.meshes.count) skins=%(_scene.skins.count) anims=%(_scene.animations.count)")

    if (_scene.animations.count == 0) Fiber.abort("the_strangler has no animations — wrong asset?")
    _anim = _scene.animations[0]
    _animTime = 0
    _speed = 1.0

    // One SkinPalette per skin (the_strangler has exactly one).
    _skinPalettes = []
    _skinScratch  = []
    for (skin in _scene.skins) {
      _skinPalettes.add(SkinPalette.new(g.device, skin.jointCount))
      _skinScratch.add(Float32Array.new(skin.jointCount * 16))
    }

    // Index each node's mesh-bearing entity into one of two
    // buckets — skinned (needs drawSkinned + palette upload) or
    // static (plain draw). spawnInto already attached the
    // MeshRenderer; we just classify.
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
    System.print("draw split: skinned=%(_skinnedRecords.count) static=%(_staticRecords.count)")

    // Sun + ambient fill.
    var sun = _world.spawn()
    _world.attach(sun, DirectionalLight.new(Vec3.new(1, 1, 1), 1.5))
    _world.attach(sun, Transform.new(
      Vec3.zero,
      Quat.fromAxisAngle(Vec3.new(1, 0, 0), -1.0),
      Vec3.one))
    var amb = _world.spawn()
    _world.attach(amb, AmbientLight.new(Vec3.new(0.25, 0.3, 0.4), 0.4))

    // Compute a fitting camera distance by sampling the bind-pose
    // bounds via the joint world transforms. Run the scene-graph
    // pass once first so each joint entity has a GlobalTransform.
    TransformPropagation.run(_world)
    var bounds = fitBounds_()
    var radius = bounds[1]
    var center = bounds[0]
    _yaw = 0.6
    _pitch = 0.15
    _distance = radius * 2.6
    _target = center
    _camera.lookAt(orbitEye_(), _target, Vec3.unitY)
  }

  // Tight-ish AABB → bounding sphere from joint world translations.
  // Good enough for an auto-frame; the underlying mesh-AABB pass
  // can land later.
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
    _animTime = _animTime + g.dt * _speed
    var dur = _anim.duration
    var tLooped = dur > 0 ? (_animTime - dur * (_animTime / dur).floor) : 0
    _anim.applyTo(_scene, _world, tLooped)

    // Orbit on left-drag.
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

  draw(g) {
    TransformPropagation.run(_world)
    composeSkinPalettes_()

    _renderer.beginFrame(g.pass, _camera)
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

  // Compose palette[k] = jointWorld_k * inverseBindMatrix_k per
  // skin, upload. Joint world matrices live in each joint
  // entity's GlobalTransform after TransformPropagation.run;
  // glTF stores IBMs column-major, so we transpose to row-major
  // for the Mat4 multiply, then transpose back to column-major
  // for the GPU upload.
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
}

Game.run(SkeletalDemo)
