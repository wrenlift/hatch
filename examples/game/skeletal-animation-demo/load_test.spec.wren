import "@hatch:gltf"   for Gltf
import "@hatch:assets" for Assets
import "@hatch:gpu"    for Gpu
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("the_strangler load") {
  Test.it("parses + uploads via the native bulk decoders") {
    var device = Gpu.requestDevice()
    var db = Assets.open("assets")
    var scene = Gltf.fromAssetsDir(device, db, "the_strangler/scene.gltf")
    System.print("nodes=%(scene.nodes.count) meshes=%(scene.meshes.count) skins=%(scene.skins.count) anims=%(scene.animations.count)")
    Expect.that(scene.skins.count).toBe(1)
    Expect.that(scene.skins[0].jointCount).toBe(102)
    Expect.that(scene.animations.count).toBe(1)
    Expect.that(scene.animations[0].channels.count > 0).toBe(true)
    // First skinned primitive must come out of fromArraysSkinned.
    var foundSkinned = false
    for (m in scene.meshes) {
      for (p in m.primitives) {
        if (p.joints != null && p.mesh != null && p.mesh.jointsBuffer != null) {
          foundSkinned = true
        }
      }
    }
    Expect.that(foundSkinned).toBe(true)
  }
}

Test.run()
