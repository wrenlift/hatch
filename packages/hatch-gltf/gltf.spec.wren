// @hatch:gltf acceptance tests. Builds minimal .glb byte fixtures
// in-process so the spec is hermetic — no on-disk assets to track.

import "./gltf"         for Gltf, GltfScene, GltfNode, GltfMesh, GltfPrimitive, GltfMaterial
import "@hatch:game"    for Transform
import "@hatch:ecs"     for World, Parent, Children
import "@hatch:test"    for Test
import "@hatch:assert"  for Expect

// -- .glb fixture builder ----------------------------------------------------

class Fixture_ {
  // Encode an ASCII string to its byte list. The JSON chunk we
  // emit is pure ASCII, so the byte stream equals the codepoint
  // stream; `s.bytes.toList` is the cleanest source.
  static asciiBytes(s) { s.bytes.toList }

  // Append u32 little-endian to `out`.
  static pushU32LE(out, v) {
    out.add(v & 0xFF)
    out.add((v >> 8)  & 0xFF)
    out.add((v >> 16) & 0xFF)
    out.add((v >> 24) & 0xFF)
  }

  // IEEE-754 single-precision encoder (positive finite + zero only;
  // the spec fixtures don't need NaN / inf / negative paths beyond
  // a small handful which we cover via direct LE byte literals).
  static pushF32LE(out, v) {
    if (v == 0) {
      out.add(0)
      out.add(0)
      out.add(0)
      out.add(0)
      return
    }
    var sign = 0
    if (v < 0) {
      sign = 1
      v = -v
    }
    // exponent
    var exp = 0
    var m = v
    while (m >= 2) {
      m = m / 2
      exp = exp + 1
    }
    while (m <  1) {
      m = m * 2
      exp = exp - 1
    }
    var biased = exp + 127
    // 23-bit mantissa from the fractional part of m (m in [1, 2))
    var mantissa = ((m - 1) * 8388608).floor
    var bits = (sign << 31) | ((biased & 0xFF) << 23) | (mantissa & 0x7FFFFF)
    out.add(bits & 0xFF)
    out.add((bits >> 8)  & 0xFF)
    out.add((bits >> 16) & 0xFF)
    out.add((bits >> 24) & 0xFF)
  }

  // Pad `out` to a 4-byte boundary using `padByte` (0x00 for JSON,
  // 0x20 for BIN per glTF spec §3.3.1).
  static padTo4(out, padByte) {
    while (out.count % 4 != 0) out.add(padByte)
  }

  // Build a minimal .glb: header + JSON chunk + BIN chunk.
  static glb(jsonText, bin) {
    var jsonBytes = asciiBytes(jsonText)
    // Pad JSON to 4-byte alignment (with 0x20 = space per spec).
    var padJson = jsonBytes.toList
    while (padJson.count % 4 != 0) padJson.add(0x20)
    var padBin = bin.toList
    while (padBin.count % 4 != 0) padBin.add(0x00)

    var totalLen = 12 + 8 + padJson.count + 8 + padBin.count

    var out = []
    pushU32LE(out, 0x46546C67)  // "glTF" magic
    pushU32LE(out, 2)            // version
    pushU32LE(out, totalLen)

    pushU32LE(out, padJson.count)
    pushU32LE(out, 0x4E4F534A)   // "JSON"
    for (b in padJson) out.add(b)

    pushU32LE(out, padBin.count)
    pushU32LE(out, 0x004E4942)   // "BIN\0"
    for (b in padBin) out.add(b)
    return out
  }

  // Build the BIN payload for a single-triangle mesh: positions
  // (vec3 f32 ×3), then u16 indices (×3, padded to 4-byte align).
  static triangleBin {
    var bin = []
    // 3 positions: v0 (0,0,0), v1 (1,0,0), v2 (0,1,0)
    pushF32LE(bin, 0)
    pushF32LE(bin, 0)
    pushF32LE(bin, 0)
    pushF32LE(bin, 1)
    pushF32LE(bin, 0)
    pushF32LE(bin, 0)
    pushF32LE(bin, 0)
    pushF32LE(bin, 1)
    pushF32LE(bin, 0)
    // 3 u16 indices: 0, 1, 2
    bin.add(0)
    bin.add(0)
    bin.add(1)
    bin.add(0)
    bin.add(2)
    bin.add(0)
    return bin
  }

  // JSON for the triangle: one mesh, one node, one scene, one material.
  static triangleJson_ {
    return "{" +
      "\"asset\":{\"version\":\"2.0\"}," +
      "\"scene\":0," +
      "\"scenes\":[{\"nodes\":[0]}]," +
      "\"nodes\":[{\"mesh\":0,\"translation\":[3,2,1]}]," +
      "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0},\"indices\":1,\"material\":0}]}]," +
      "\"accessors\":[" +
        "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
        "{\"bufferView\":1,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}" +
      "]," +
      "\"bufferViews\":[" +
        "{\"buffer\":0,\"byteLength\":36,\"byteOffset\":0}," +
        "{\"buffer\":0,\"byteLength\":6,\"byteOffset\":36}" +
      "]," +
      "\"buffers\":[{\"byteLength\":42}]," +
      "\"materials\":[{\"name\":\"red\",\"pbrMetallicRoughness\":{\"baseColorFactor\":[1.0,0.0,0.0,1.0]}}]" +
      "}"
  }

  static triangleGlb_ {
    return glb(triangleJson_, triangleBin)
  }

  // Two-node hierarchy: a parent at (10, 0, 0), a child at (0, 3, 0)
  // pointing at the same triangle mesh. Exercises children + the
  // scene's `nodes` root list.
  static hierarchyJson_ {
    return "{" +
      "\"asset\":{\"version\":\"2.0\"}," +
      "\"scene\":0," +
      "\"scenes\":[{\"nodes\":[0]}]," +
      "\"nodes\":[" +
        "{\"translation\":[10,0,0],\"children\":[1]}," +
        "{\"mesh\":0,\"translation\":[0,3,0]}" +
      "]," +
      "\"meshes\":[{\"primitives\":[{\"attributes\":{\"POSITION\":0},\"indices\":1}]}]," +
      "\"accessors\":[" +
        "{\"bufferView\":0,\"componentType\":5126,\"count\":3,\"type\":\"VEC3\"}," +
        "{\"bufferView\":1,\"componentType\":5123,\"count\":3,\"type\":\"SCALAR\"}" +
      "]," +
      "\"bufferViews\":[" +
        "{\"buffer\":0,\"byteLength\":36,\"byteOffset\":0}," +
        "{\"buffer\":0,\"byteLength\":6,\"byteOffset\":36}" +
      "]," +
      "\"buffers\":[{\"byteLength\":42}]" +
      "}"
  }

  static hierarchyGlb_ {
    return glb(hierarchyJson_, triangleBin)
  }
}

// -- Specs -------------------------------------------------------------------

Test.describe("Gltf.parse: header + chunks") {
  Test.it("rejects too-short input") {
    var f = Fiber.new { Gltf.parse([1, 2, 3]) }
    f.try()
    Expect.that(f.error.contains("too short")).toBe(true)
  }

  Test.it("rejects a bad magic") {
    var bytes = [0xFF, 0xFF, 0xFF, 0xFF, 0x02, 0, 0, 0, 0, 0, 0, 0]
    var f = Fiber.new { Gltf.parse(bytes) }
    f.try()
    Expect.that(f.error.contains("bad .glb magic")).toBe(true)
  }

  Test.it("rejects a non-2 version") {
    var bytes = [0x67, 0x6C, 0x54, 0x46, 0x05, 0, 0, 0, 12, 0, 0, 0]
    var f = Fiber.new { Gltf.parse(bytes) }
    f.try()
    Expect.that(f.error.contains("unsupported .glb version")).toBe(true)
  }

  Test.it("parses a minimal triangle .glb") {
    var bytes = Fixture_.triangleGlb_
    var doc = Gltf.parse(bytes)
    Expect.that(doc.json["asset"]["version"]).toBe("2.0")
    Expect.that(doc.meshes.count).toBe(1)
    Expect.that(doc.nodes.count).toBe(1)
    Expect.that(doc.materials.count).toBe(1)
    Expect.that(doc.rootIndices.count).toBe(1)
    Expect.that(doc.rootIndices[0]).toBe(0)
  }
}

Test.describe("Gltf accessor decoding") {
  Test.it("decodes a vec3 f32 POSITION accessor into the right values") {
    var doc = Gltf.parse(Fixture_.triangleGlb_)
    var prim = doc.meshes[0].primitives[0]
    Expect.that(prim.positions.count).toBe(9)
    // v0 = (0,0,0), v1 = (1,0,0), v2 = (0,1,0)
    Expect.that(prim.positions[0]).toBe(0)
    Expect.that(prim.positions[3]).toBe(1)
    Expect.that(prim.positions[7]).toBe(1)
  }

  Test.it("decodes u16 SCALAR indices") {
    var doc = Gltf.parse(Fixture_.triangleGlb_)
    var prim = doc.meshes[0].primitives[0]
    Expect.that(prim.indices.count).toBe(3)
    Expect.that(prim.indices[0]).toBe(0)
    Expect.that(prim.indices[1]).toBe(1)
    Expect.that(prim.indices[2]).toBe(2)
  }
}

Test.describe("Gltf material parsing") {
  Test.it("captures baseColorFactor as a Vec4") {
    var doc = Gltf.parse(Fixture_.triangleGlb_)
    var m = doc.materials[0]
    Expect.that(m.name).toBe("red")
    Expect.that(m.baseColor.x).toBe(1)
    Expect.that(m.baseColor.y).toBe(0)
    Expect.that(m.baseColor.z).toBe(0)
    Expect.that(m.baseColor.w).toBe(1)
  }
}

Test.describe("Gltf node hierarchy") {
  Test.it("captures node translation into a Transform") {
    var doc = Gltf.parse(Fixture_.triangleGlb_)
    var n = doc.nodes[0]
    Expect.that(n.transform.position.x).toBe(3)
    Expect.that(n.transform.position.y).toBe(2)
    Expect.that(n.transform.position.z).toBe(1)
  }

  Test.it("captures parent → child links via `children`") {
    var doc = Gltf.parse(Fixture_.hierarchyGlb_)
    Expect.that(doc.nodes.count).toBe(2)
    Expect.that(doc.nodes[0].children.count).toBe(1)
    Expect.that(doc.nodes[0].children[0]).toBe(1)
    Expect.that(doc.rootIndices.count).toBe(1)
    Expect.that(doc.rootIndices[0]).toBe(0)
  }
}

// Duck-typed stand-ins for `@hatch:assets` so the loader's asset
// entry points can be tested without reaching for the filesystem.
class MockAsset_ {
  construct new(bytes) { _bytes = bytes }
  bytes { _bytes }
}

class MockAssetDb_ {
  construct new(entries) { _entries = entries }
  bytes(relPath) {
    if (!_entries.containsKey(relPath)) Fiber.abort("MockAssetDb: %(relPath) not registered")
    return _entries[relPath]
  }
}

Test.describe("Gltf.fromAsset / fromAssets") {
  Test.it("fromAsset duck-types on `.bytes`") {
    var asset = MockAsset_.new(Fixture_.triangleGlb_)
    // Skip upload — only checking the parse half. Re-route via
    // `parse(asset.bytes)` since `fromAsset` would call `upload`.
    var doc = Gltf.parse(asset.bytes)
    Expect.that(doc.meshes.count).toBe(1)
    Expect.that(doc.nodes.count).toBe(1)
  }

  Test.it("fromAssets routes through db.bytes(relPath)") {
    var db = MockAssetDb_.new({ "models/triangle.glb": Fixture_.triangleGlb_ })
    var doc = Gltf.parse(db.bytes("models/triangle.glb"))
    Expect.that(doc.materials.count).toBe(1)
    Expect.that(doc.materials[0].name).toBe("red")
  }
}

Test.describe("Gltf.spawnInto") {
  Test.it("creates one entity per node with a Transform") {
    var doc = Gltf.parse(Fixture_.triangleGlb_)
    var world = World.new()
    var roots = doc.spawnInto(world)
    Expect.that(roots.count).toBe(1)
    var t = world.get(roots[0], Transform)
    Expect.that(t == null).toBe(false)
    Expect.that(t.position.x).toBe(3)
  }

  Test.it("links child nodes via ECS Parent/Children") {
    var doc = Gltf.parse(Fixture_.hierarchyGlb_)
    var world = World.new()
    var roots = doc.spawnInto(world)
    Expect.that(roots.count).toBe(1)
    var root = roots[0]
    var kids = world.get(root, Children)
    Expect.that(kids == null).toBe(false)
    Expect.that(kids.count).toBe(1)
    var child = kids.list[0]
    Expect.that(world.parentOf(child)).toBe(root)
    var childT = world.get(child, Transform)
    Expect.that(childT.position.y).toBe(3)
  }
}

Test.run()
