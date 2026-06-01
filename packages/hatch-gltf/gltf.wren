// `@hatch:gltf` — pure-Wren glTF 2.0 loader.
//
//   import "@hatch:gltf" for Gltf
//
//   // Single-file .glb (everything embedded):
//   var doc = Gltf.load(device, bytes)
//
//   // Multi-file .gltf with sibling .bin + textures:
//   var db  = Assets.open("assets")
//   var doc = Gltf.fromAssetsDir(device, db, "nature-kit/models/tree.gltf")
//
//   doc.spawnInto(world)                 // entities + Transform + MeshRenderer
//
// Supports: .glb container parsing (single-file binary), external
// `.gltf+.bin+.png` packs resolved through `@hatch:assets`, node
// hierarchy with translation/rotation/scale → Transform, indexed
// triangle meshes with position + normal + uv accessors, material
// baseColorFactor read into a flat Material, multi-buffer +
// multi-texture indirection via `bufferView.buffer`.
//
// Not yet supported: animations + channels, skins + joints, KHR
// extensions beyond pbrMetallicRoughness defaults, sparse accessors,
// point / line primitives, morph targets, cameras. Each lands when
// the downstream feature needs it.

import "@hatch:json"  for JSON
import "@hatch:math"  for Vec3, Vec4, Quat
import "@hatch:gpu"   for Mesh, Material
import "@hatch:image" for Image
import "@hatch:game"  for Transform, MeshRenderer

// .glb magic: 0x46546C67  ("glTF" little-endian).
var GLB_MAGIC_ = 0x46546C67
var CHUNK_JSON_ = 0x4E4F534A   // "JSON"
var CHUNK_BIN_  = 0x004E4942   // "BIN\0"

/// Front-door static. Hands back a `GltfScene` you can either
/// inspect directly (parse-only flow) or hand to a GPU device for
/// upload + ECS spawn.
class Gltf {
  /// Parse a `.glb` byte sequence. Accepts a `ByteArray` or any
  /// indexable `List<Num>` (0..255 elements). Validates the
  /// magic + chunk layout, decodes the JSON chunk via
  /// `@hatch:json`, and stashes the BIN buffer as a `ByteArray`
  /// for later accessor reads. Mesh / material / texture data
  /// isn't converted until `upload` runs; this is a pure-data
  /// step suitable for headless tests.
  ///
  /// @param {ByteArray|List<Num>} bytes
  /// @returns {GltfScene}
  static parse(bytes) {
    return GltfScene.parse_(bytes)
  }

  /// Parse + upload mesh primitives to `device` in one call. The
  /// returned document's `meshes[i].primitives[j].mesh` slot is
  /// populated with a real `@hatch:gpu` `Mesh` ready to render.
  ///
  /// @param {Device} device
  /// @param {ByteArray|List<Num>} bytes
  /// @returns {GltfScene}
  static load(device, bytes) {
    var d = parse(bytes)
    d.upload(device)
    return d
  }

  /// Load a .glb from an `@hatch:assets` `Asset` (or any object
  /// that exposes a `bytes` getter returning a `ByteArray` /
  /// `List<Num>`). Convenience over the common
  /// `Gltf.load(device, asset.bytes)` pattern, and a clean place
  /// to hang hot-reload glue:
  ///
  /// ```wren
  /// var db    = Assets.open("assets")
  /// var model = Gltf.fromAsset(device, db.get("models/player.glb"))
  /// db.on("models/player.glb") {|asset|
  ///   model = Gltf.fromAsset(device, asset)
  /// }
  /// ```
  ///
  /// `@hatch:gltf` doesn't import `@hatch:assets` directly — the
  /// argument is duck-typed on `.bytes` so test mocks and other
  /// asset abstractions work too.
  ///
  /// @param {Device} device
  /// @param {Asset} asset. Any object exposing a `bytes` getter
  ///   that returns a `ByteArray` (or `List<Num>`).
  /// @returns {GltfScene}
  static fromAsset(device, asset) {
    return load(device, asset.bytes)
  }

  /// Resolve a relative path against an `@hatch:assets` `Assets`
  /// database and load the resulting .glb. The database is
  /// duck-typed on `.bytes(relPath)` so the loader doesn't pull
  /// `@hatch:assets` as a hard dep.
  ///
  /// ```wren
  /// var db    = Assets.open("assets")
  /// var model = Gltf.fromAssets(device, db, "models/player.glb")
  /// ```
  ///
  /// @param {Device} device
  /// @param {Assets} db. Object with a `bytes(relPath)` method.
  /// @param {String} relPath. Path into the assets database.
  /// @returns {GltfScene}
  static fromAssets(device, db, relPath) {
    return load(device, db.bytes(relPath))
  }

  /// Load an external-format glTF (text `.gltf` + sibling `.bin`
  /// buffers + image files) via an `@hatch:assets` database.
  ///
  /// The loader reads the .gltf text from `gltfPath`, walks
  /// `buffers[]` and `images[]` resolving each external `uri`
  /// relative to the .gltf's directory, and constructs a
  /// `GltfScene` with every buffer / image preloaded. Then it
  /// uploads to the GPU device and returns the populated scene.
  ///
  /// Quaternius packs and most online sources (Sketchfab,
  /// Polyhaven) ship in this multi-file layout — useful when you
  /// want the textures to be inspectable / hot-reloadable as PNGs
  /// rather than baked into a .glb blob.
  ///
  /// `db` is duck-typed on `.bytes(relPath)` for both the .gltf
  /// text (decoded as ASCII / UTF-8) and the binary sidecars.
  ///
  /// @param {Device} device
  /// @param {Assets} db. Object with a `bytes(relPath)` method.
  /// @param {String} gltfPath. Path to the .gltf file inside `db`.
  /// @returns {GltfScene}
  static fromAssetsDir(device, db, gltfPath) {
    var dir = GltfScene.dirname_(gltfPath)
    var jsonBytes = db.bytes(gltfPath)
    var jsonText = Bytes_.asciiString(jsonBytes, 0, jsonBytes.count)
    var json = JSON.parse(GltfScene.stripPad_(jsonText))
    if (!(json is Map)) Fiber.abort("Gltf.fromAssetsDir: %(gltfPath) did not decode to a JSON object")

    // Resolve every `buffers[i]` entry. External URI: load via db.
    // Embedded base64 data URI: also supported (rare for nature-kit
    // packs but trivial since we already have the JSON).
    var buffers = []
    var bufArr = json["buffers"]
    if (bufArr is List) {
      for (bEntry in bufArr) {
        if (!(bEntry is Map)) Fiber.abort("Gltf.fromAssetsDir: bad buffer entry")
        var uri = bEntry["uri"]
        if (!(uri is String)) Fiber.abort("Gltf.fromAssetsDir: buffer missing uri (.glb-style embedded BIN is the load() path)")
        if (uri.startsWith("data:")) {
          Fiber.abort("Gltf.fromAssetsDir: data: URIs not yet supported — externalise the buffer or use .glb")
        }
        var bufPath = GltfScene.joinPath_(dir, uri)
        buffers.add(db.bytes(bufPath))
      }
    }

    // Resolve every `images[i]` entry with a URI. We don't decode
    // here — we hand off raw bytes to the upload path so the same
    // Image.decode + uploadImage call site handles both embedded
    // and external images.
    var externalImageBytes = []
    var imgs = json["images"]
    if (imgs is List) {
      for (im in imgs) {
        if (im is Map && im["uri"] is String && !im["uri"].startsWith("data:")) {
          var imgPath = GltfScene.joinPath_(dir, im["uri"])
          externalImageBytes.add(db.bytes(imgPath))
        } else {
          externalImageBytes.add(null)
        }
      }
    }

    var scene = GltfScene.fromJson_(json, buffers, externalImageBytes)
    scene.upload(device)
    return scene
  }
}

// Byte-reader helpers. The .glb format is little-endian; the JSON
// chunk is the parsed source of truth for everything after the
// header, but accessor data inside the BIN chunk is still framed
// as raw bytes that we walk a row at a time.
class Bytes_ {
  static u32LE(b, o) {
    return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)
  }

  static u16LE(b, o) {
    return b[o] | (b[o + 1] << 8)
  }

  // IEEE-754 single-precision decode. Subnormals, infinities and
  // NaN are honoured even though glTF accessors never legally
  // contain them — bailing out into Wren's native ±Inf / NaN
  // values is cheaper than aborting and lets downstream code
  // detect malformed buffers at use time, where the error
  // message can be field-specific.
  static f32LE(b, o) {
    var b0 = b[o]
    var b1 = b[o + 1]
    var b2 = b[o + 2]
    var b3 = b[o + 3]
    var sign = (b3 & 0x80) == 0 ? 1 : -1
    var exp  = ((b3 & 0x7F) << 1) | ((b2 & 0x80) >> 7)
    var mant = ((b2 & 0x7F) << 16) | (b1 << 8) | b0
    if (exp == 0) {
      if (mant == 0) return sign * 0
      // subnormal: sign * mant * 2^-149
      return sign * mant * (2.pow(-149))
    }
    if (exp == 0xFF) {
      if (mant == 0) return sign * (1.0 / 0.0)
      return 0.0 / 0.0
    }
    var fraction = 1 + mant / 8388608   // 2^23
    return sign * fraction * (2.pow(exp - 127))
  }

  /// Read a UTF-8-ish ASCII string over a byte slice. JSON chunks
  /// from the wild are UTF-8 by spec but the glTF JSON portion is
  /// pure ASCII metadata; sticking to raw codepoints keeps the
  /// parser self-contained.
  static asciiString(b, off, len) {
    var chars = []
    var i = 0
    while (i < len) {
      chars.add(String.fromCodePoint(b[off + i]))
      i = i + 1
    }
    return chars.join("")
  }
}

/// Parsed glTF scene. Holds the raw JSON tree, the BIN buffer
/// (`ByteArray`), and the constructed `GltfNode` / `GltfMesh` /
/// `GltfMaterial` views. `Gltf.load` runs the GPU upload pass
/// over a `GltfScene`; `spawnInto(world)` walks the default-scene
/// root nodes into ECS entities.
class GltfScene {
  /// Internal — constructed by `Gltf.parse` (for .glb) or
  /// `Gltf.fromAssetsDir` (for external .gltf+.bin). User code
  /// goes through `Gltf.parse` / `Gltf.load` / `Gltf.fromAssetsDir`.
  ///
  /// @param {Map} json. The decoded glTF JSON tree.
  /// @param {List<ByteArray>} buffers. One entry per `json["buffers"]`
  ///   index; .glb supplies a single entry (the BIN chunk).
  /// @param {List<ByteArray|null>} externalImageBytes. Optional —
  ///   one entry per `json["images"]` index, raw PNG/JPG bytes
  ///   for images loaded via external URI. `null` for embedded
  ///   (`bufferView`-based) images or absent slots.
  construct new_(json, buffers, externalImageBytes) {
    _json     = json
    _buffers  = buffers
    _materials      = GltfScene.buildMaterials_(json)
    _meshes         = GltfScene.buildMeshes_(json, _buffers)
    _nodes          = GltfScene.buildNodes_(json)
    _rootIndices    = GltfScene.pickRootIndices_(json)
    // One image-descriptor entry per glTF `images[i]`. Each entry
    // is either `null` (no source) or a Map with `"kind"`:
    //   - "buffer": embedded image in a bufferView — `"buffer"` /
    //     `"byteOffset"` / `"byteLength"` for the slice.
    //   - "bytes":  external image loaded via URI — `"bytes"` holds
    //     the raw PNG/JPG payload, decoded at upload time.
    // The sRGB flag is set per how each material slot uses the
    // image (albedo + emissive = sRGB; MR / normal / occlusion =
    // linear). Pass the parsed `_materials` list so the builder
    // can walk each material's slot indices.
    _imageSources   = GltfScene.buildImageSources_(json, _materials, externalImageBytes)
    // Populated by `upload(device)` — same length as
    // `_imageSources`, each entry an uploaded `Texture` or
    // `null` when the source couldn't be decoded.
    _imageTextures  = []
  }

  /// The parsed top-level glTF JSON tree (Map). Use this for
  /// fields the loader hasn't promoted to first-class accessors
  /// (extensions, asset.copyright, etc.).
  json         { _json }

  /// The first buffer's bytes as a `ByteArray`. Convenience for
  /// .glb consumers (where there's only one buffer). External
  /// multi-buffer scenes have multiple — use `buffers` for the full
  /// list. Returns an empty ByteArray when no buffers are present.
  binBuffer    { _buffers.isEmpty ? ByteArray.new(0) : _buffers[0] }

  /// All buffers, in `json["buffers"]` order. .glb scenes have one
  /// entry (the BIN chunk); external .gltf scenes have one per
  /// sidecar .bin file.
  buffers      { _buffers }

  materials    { _materials }   // List<GltfMaterial>
  meshes       { _meshes }      // List<GltfMesh>
  nodes        { _nodes }       // List<GltfNode>
  rootIndices  { _rootIndices } // List<Num> — top-level nodes of the default scene

  // ---- Construction ----------------------------------------------

  static parse_(bytes) {
    if (bytes.count < 12) Fiber.abort("Gltf.parse: too short — needs at least a 12-byte header")
    var magic = Bytes_.u32LE(bytes, 0)
    if (magic != GLB_MAGIC_) {
      Fiber.abort("Gltf.parse: bad .glb magic 0x%(magic) (expected 'glTF')")
    }
    var version = Bytes_.u32LE(bytes, 4)
    if (version != 2) {
      Fiber.abort("Gltf.parse: unsupported .glb version %(version) (only 2 is implemented)")
    }
    var total = Bytes_.u32LE(bytes, 8)
    if (total > bytes.count) {
      Fiber.abort("Gltf.parse: header length %(total) exceeds blob size %(bytes.count)")
    }

    var json = null
    var bin  = ByteArray.new(0)
    var off  = 12
    while (off < total) {
      if (off + 8 > total) {
        Fiber.abort("Gltf.parse: truncated chunk header at offset %(off)")
      }
      var chunkLen  = Bytes_.u32LE(bytes, off)
      var chunkType = Bytes_.u32LE(bytes, off + 4)
      var dataStart = off + 8
      var dataEnd   = dataStart + chunkLen
      if (dataEnd > total) {
        Fiber.abort("Gltf.parse: chunk at offset %(off) overruns the blob")
      }
      if (chunkType == CHUNK_JSON_) {
        if (json != null) Fiber.abort("Gltf.parse: more than one JSON chunk")
        var text = Bytes_.asciiString(bytes, dataStart, chunkLen)
        // Trim trailing pad bytes (0x00 for JSON, 0x20 spaces sometimes
        // appended by exporters before alignment).
        json = JSON.parse(GltfScene.stripPad_(text))
      } else if (chunkType == CHUNK_BIN_) {
        if (bin.count > 0) Fiber.abort("Gltf.parse: more than one BIN chunk")
        // Copy the chunk into a packed ByteArray. One contiguous
        // allocation rather than N boxed Nums; downstream accessors
        // index it directly via `bin[i]`.
        bin = ByteArray.new(chunkLen)
        var i = 0
        while (i < chunkLen) {
          bin[i] = bytes[dataStart + i]
          i = i + 1
        }
      }
      // Unknown chunk types are silently skipped per glTF spec §3.3.
      off = dataEnd
    }
    if (json == null) Fiber.abort("Gltf.parse: no JSON chunk found")
    if (!(json is Map)) Fiber.abort("Gltf.parse: JSON chunk did not decode to an object")
    return GltfScene.new_(json, [bin], [])
  }

  // Build a scene from already-resolved external buffers + image
  // bytes. The fromAssetsDir front door uses this; tests and other
  // callers with their own asset-resolution can too.
  static fromJson_(json, buffers, externalImageBytes) {
    return GltfScene.new_(json, buffers, externalImageBytes)
  }

  // Strip the directory component off `path`, returning everything
  // up to and including the last "/", or "" if there's no slash.
  // Used to anchor relative URIs in a .gltf against the .gltf's own
  // directory inside the assets database.
  static dirname_(path) {
    var i = path.count - 1
    while (i >= 0) {
      if (path[i] == "/") return path[0..i]
      i = i - 1
    }
    return ""
  }

  // Combine a directory prefix with a relative URI. Absolute URIs
  // (those starting with "/") replace the prefix.
  static joinPath_(dir, uri) {
    if (uri.startsWith("/")) return uri[1..-1]
    return dir + uri
  }

  static stripPad_(s) {
    var n = s.count
    while (n > 0) {
      var c = s[n - 1]
      if (c != " " && c != "\0") break
      n = n - 1
    }
    return n == s.count ? s : s[0...n]
  }

  // -- Materials ---------------------------------------------------

  // glTF `texture` entries are an indirection: each one references
  // a `source` (image index) + optional `sampler`. We collapse the
  // chain here — every texture index in a material slot resolves
  // directly to its underlying image index so the upload path
  // only has to track images.
  static textureToImageMap_(json) {
    var out = []
    var arr = json["textures"]
    if (!(arr is List)) return out
    for (t in arr) {
      if (t is Map && t["source"] is Num) {
        out.add(t["source"])
      } else {
        out.add(null)
      }
    }
    return out
  }

  // Resolve a glTF texture-info entry (`{ "index": N, ... }`) into
  // the underlying image index, or `null` when the slot is absent /
  // malformed.
  static imageIndexOf_(json, t2i, slot) {
    if (!(slot is Map)) return null
    if (!(slot["index"] is Num)) return null
    var texIdx = slot["index"]
    if (texIdx >= t2i.count) return null
    return t2i[texIdx]
  }

  static buildMaterials_(json) {
    var out = []
    var arr = json["materials"]
    if (!(arr is List)) return out
    var t2i = GltfScene.textureToImageMap_(json)
    for (m in arr) {
      var name = m["name"] is String ? m["name"] : ""
      var bc   = Vec4.new(1, 1, 1, 1)
      var metallic  = 1.0
      var roughness = 1.0
      var albedoImgIdx = null
      var mrImgIdx     = null
      var pbr = m["pbrMetallicRoughness"]
      if (pbr is Map) {
        var bcf = pbr["baseColorFactor"]
        if (bcf is List && bcf.count >= 4) {
          bc = Vec4.new(bcf[0], bcf[1], bcf[2], bcf[3])
        }
        if (pbr["metallicFactor"]  is Num) metallic  = pbr["metallicFactor"]
        if (pbr["roughnessFactor"] is Num) roughness = pbr["roughnessFactor"]
        albedoImgIdx = GltfScene.imageIndexOf_(json, t2i, pbr["baseColorTexture"])
        mrImgIdx     = GltfScene.imageIndexOf_(json, t2i, pbr["metallicRoughnessTexture"])
      }
      var normalImgIdx    = GltfScene.imageIndexOf_(json, t2i, m["normalTexture"])
      var occlusionImgIdx = GltfScene.imageIndexOf_(json, t2i, m["occlusionTexture"])
      var emissiveImgIdx  = GltfScene.imageIndexOf_(json, t2i, m["emissiveTexture"])

      var normalScale = 1.0
      if (m["normalTexture"] is Map && m["normalTexture"]["scale"] is Num) {
        normalScale = m["normalTexture"]["scale"]
      }
      var occlusionStrength = 1.0
      if (m["occlusionTexture"] is Map && m["occlusionTexture"]["strength"] is Num) {
        occlusionStrength = m["occlusionTexture"]["strength"]
      }
      var emissive = Vec4.new(0, 0, 0, 1)
      if (m["emissiveFactor"] is List && m["emissiveFactor"].count >= 3) {
        var e = m["emissiveFactor"]
        emissive = Vec4.new(e[0], e[1], e[2], 1.0)
      }
      // glTF spec writes "OPAQUE" / "MASK" / "BLEND"; the
      // renderer's Material accepts "opaque" / "mask" / "blend".
      // Match the spec's uppercase forms explicitly rather than
      // lower-casing the string — Wren's String surface has no
      // built-in case conversion.
      var alphaMode = "opaque"
      if (m["alphaMode"] == "MASK")  alphaMode = "mask"
      if (m["alphaMode"] == "BLEND") alphaMode = "blend"
      var alphaCutoff  = m["alphaCutoff"] is Num ? m["alphaCutoff"] : 0.5
      var doubleSided  = m["doubleSided"] == true

      out.add(GltfMaterial.new_(
        name,
        bc, metallic, roughness,
        albedoImgIdx, mrImgIdx, normalImgIdx, normalScale,
        occlusionImgIdx, occlusionStrength,
        emissiveImgIdx, emissive,
        alphaMode, alphaCutoff, doubleSided))
    }
    return out
  }

  // -- Images ------------------------------------------------------

  // Walk `images[]` building a per-image source descriptor + sRGB
  // flag. Each entry is either:
  //   - `null` — no source we can decode
  //   - `{ "kind": "buffer", "buffer": N, "byteOffset": X, "byteLength": Y, "sRGB": flag }`
  //     for .glb-embedded images (a bufferView slice into one of
  //     the loaded buffers)
  //   - `{ "kind": "bytes", "bytes": ByteArray, "sRGB": flag }`
  //     for external-URI images that have been preloaded by the
  //     fromAssetsDir entry point
  //
  // sRGB tagging: each material slot has a fixed expected encoding
  // by the glTF spec — `baseColor` + `emissive` are sRGB,
  // `metallicRoughness` + `normal` + `occlusion` are linear. We
  // walk every material and tag each referenced image accordingly.
  // If an image is referenced by both an sRGB and a linear slot
  // (rare in practice), sRGB wins so albedo paths render correctly.
  static buildImageSources_(json, materials, externalImageBytes) {
    var imgs = json["images"]
    if (!(imgs is List)) return []

    var srgbFlags = []
    var i = 0
    while (i < imgs.count) {
      srgbFlags.add(false)
      i = i + 1
    }
    for (m in materials) {
      if (m.albedoImageIndex   != null) srgbFlags[m.albedoImageIndex]   = true
      if (m.emissiveImageIndex != null) srgbFlags[m.emissiveImageIndex] = true
      // MR / normal / occlusion stay `false` (linear).
    }

    var out = []
    var idx = 0
    while (idx < imgs.count) {
      var im = imgs[idx]
      // External URI first: caller pre-loaded the file bytes.
      if (idx < externalImageBytes.count && externalImageBytes[idx] != null) {
        out.add({
          "kind":  "bytes",
          "bytes": externalImageBytes[idx],
          "sRGB":  srgbFlags[idx],
        })
      } else if (im is Map && im["bufferView"] is Num) {
        var bvIdx = im["bufferView"]
        var bvs   = json["bufferViews"]
        if (!(bvs is List) || bvIdx >= bvs.count) {
          out.add(null)
        } else {
          var bv = bvs[bvIdx]
          out.add({
            "kind":       "buffer",
            "buffer":     bv["buffer"] is Num ? bv["buffer"] : 0,
            "byteOffset": bv["byteOffset"] is Num ? bv["byteOffset"] : 0,
            "byteLength": bv["byteLength"],
            "sRGB":       srgbFlags[idx],
          })
        }
      } else {
        // No source field, can't resolve.
        out.add(null)
      }
      idx = idx + 1
    }
    return out
  }

  // -- Meshes ------------------------------------------------------

  static buildMeshes_(json, buffers) {
    var out = []
    var arr = json["meshes"]
    if (!(arr is List)) return out
    for (m in arr) {
      var name = m["name"] is String ? m["name"] : ""
      var prims = []
      var pl = m["primitives"]
      if (pl is List) {
        for (p in pl) prims.add(GltfScene.extractPrimitive_(json, buffers, p))
      }
      out.add(GltfMesh.new_(name, prims))
    }
    return out
  }

  static extractPrimitive_(json, buffers, p) {
    if (!(p is Map)) Fiber.abort("Gltf: primitive is not an object")
    var attrs = p["attributes"]
    if (!(attrs is Map)) Fiber.abort("Gltf: primitive has no attributes")

    var posIdx = attrs["POSITION"]
    if (!(posIdx is Num)) Fiber.abort("Gltf: primitive missing required POSITION accessor")
    var positions = GltfScene.readVec3Accessor_(json, buffers, posIdx)

    var normals = null
    var normIdx = attrs["NORMAL"]
    if (normIdx is Num) normals = GltfScene.readVec3Accessor_(json, buffers, normIdx)

    var uvs = null
    var uvIdx = attrs["TEXCOORD_0"]
    if (uvIdx is Num) uvs = GltfScene.readVec2Accessor_(json, buffers, uvIdx)

    var indices = null
    if (p["indices"] is Num) indices = GltfScene.readIndexAccessor_(json, buffers, p["indices"])

    var materialIndex = p["material"] is Num ? p["material"] : null
    return GltfPrimitive.new_(positions, normals, uvs, indices, materialIndex)
  }

  // -- Nodes -------------------------------------------------------

  static buildNodes_(json) {
    var out = []
    var arr = json["nodes"]
    if (!(arr is List)) return out
    for (n in arr) {
      out.add(GltfScene.buildNode_(n))
    }
    return out
  }

  static buildNode_(n) {
    var name = n["name"] is String ? n["name"] : ""
    var t = Vec3.zero
    var r = Quat.identity
    var s = Vec3.one
    if (n["translation"] is List && n["translation"].count >= 3) {
      var v = n["translation"]
      t = Vec3.new(v[0], v[1], v[2])
    }
    if (n["rotation"] is List && n["rotation"].count >= 4) {
      // glTF stores rotation as (x, y, z, w); Quat is (w, x, y, z).
      var v = n["rotation"]
      r = Quat.new(v[3], v[0], v[1], v[2])
    }
    if (n["scale"] is List && n["scale"].count >= 3) {
      var v = n["scale"]
      s = Vec3.new(v[0], v[1], v[2])
    }
    var transform = Transform.new(t, r, s)

    var meshIndex = n["mesh"] is Num ? n["mesh"] : null
    var children = []
    if (n["children"] is List) {
      for (idx in n["children"]) {
        if (idx is Num) children.add(idx)
      }
    }
    return GltfNode.new_(name, transform, meshIndex, children)
  }

  // glTF's `scene` field picks the default scene root; if absent
  // (or invalid) fall back to "every node that isn't somebody's
  // child" — same rule blender / Cesium use when exporting orphan
  // top-level meshes.
  static pickRootIndices_(json) {
    var scenes = json["scenes"]
    var sceneIdx = json["scene"] is Num ? json["scene"] : 0
    if (scenes is List && sceneIdx < scenes.count) {
      var s = scenes[sceneIdx]
      if (s is Map && s["nodes"] is List) {
        var out = []
        for (i in s["nodes"]) {
          if (i is Num) out.add(i)
        }
        return out
      }
    }
    // Fallback: every node not listed as some other node's child.
    var nodes = json["nodes"]
    if (!(nodes is List)) return []
    var hasParent = {}
    for (n in nodes) {
      if (n is Map && n["children"] is List) {
        for (c in n["children"]) {
          if (c is Num) hasParent[c] = true
        }
      }
    }
    var out = []
    var i = 0
    while (i < nodes.count) {
      if (!hasParent.containsKey(i)) out.add(i)
      i = i + 1
    }
    return out
  }

  // -- Accessor reads ---------------------------------------------

  static accessorAt_(json, idx) {
    var accs = json["accessors"]
    if (!(accs is List) || idx >= accs.count) Fiber.abort("Gltf: accessor %(idx) out of range")
    return accs[idx]
  }

  static bufferViewAt_(json, idx) {
    var bvs = json["bufferViews"]
    if (!(bvs is List) || idx >= bvs.count) Fiber.abort("Gltf: bufferView %(idx) out of range")
    return bvs[idx]
  }

  // Resolve a bufferView entry to the byte source: `(bin, byteOffset)`
  // where `bin` is the underlying `ByteArray`. bv["buffer"] defaults
  // to 0 when absent (matches .glb's single-buffer convention).
  static binFromBufferView_(buffers, bv) {
    var bufIdx = bv["buffer"] is Num ? bv["buffer"] : 0
    if (bufIdx >= buffers.count) {
      Fiber.abort("Gltf: bufferView references buffer %(bufIdx) but only %(buffers.count) buffer(s) loaded")
    }
    return buffers[bufIdx]
  }

  static readVec3Accessor_(json, buffers, idx) {
    return GltfScene.readFloatAccessor_(json, buffers, idx, 3, "VEC3")
  }

  static readVec2Accessor_(json, buffers, idx) {
    return GltfScene.readFloatAccessor_(json, buffers, idx, 2, "VEC2")
  }

  // Reads a contiguous f32-typed accessor into a packed
  // `Float32Array` (one allocation, `count * components`
  // elements). Strided bufferViews (`byteStride`) are honoured so
  // interleaved glTF exports parse correctly; the output is
  // always packed.
  static readFloatAccessor_(json, buffers, idx, components, expectedType) {
    var a = GltfScene.accessorAt_(json, idx)
    if (a["type"] != expectedType) {
      Fiber.abort("Gltf: accessor %(idx) is %(a["type"]), expected %(expectedType)")
    }
    if (a["componentType"] != 5126) {     // 5126 = GL_FLOAT
      Fiber.abort("Gltf: accessor %(idx) componentType %(a["componentType"]), expected 5126 (FLOAT)")
    }
    var bvIdx = a["bufferView"]
    if (!(bvIdx is Num)) Fiber.abort("Gltf: float accessor %(idx) has no bufferView")
    var bv = GltfScene.bufferViewAt_(json, bvIdx)
    var bin = GltfScene.binFromBufferView_(buffers, bv)
    var byteOffset = (a["byteOffset"] is Num ? a["byteOffset"] : 0) +
                     (bv["byteOffset"] is Num ? bv["byteOffset"] : 0)
    var count = a["count"]
    var stride = bv["byteStride"] is Num ? bv["byteStride"] : (components * 4)
    var out = Float32Array.new(count * components)
    var i = 0
    while (i < count) {
      var rowOff = byteOffset + i * stride
      var c = 0
      while (c < components) {
        out[i * components + c] = Bytes_.f32LE(bin, rowOff + c * 4)
        c = c + 1
      }
      i = i + 1
    }
    return out
  }

  // Reads a u8/u16/u32 SCALAR index accessor into a packed
  // `Int32Array`. i32 is plenty for any realistic mesh (max 2³¹
  // vertices) and matches `Mesh.fromArrays`'s u32 index buffer.
  static readIndexAccessor_(json, buffers, idx) {
    var a = GltfScene.accessorAt_(json, idx)
    if (a["type"] != "SCALAR") {
      Fiber.abort("Gltf: index accessor %(idx) type %(a["type"]), expected SCALAR")
    }
    var componentType = a["componentType"]
    var elemSize = 0
    if      (componentType == 5121) { elemSize = 1 }   // u8
    else if (componentType == 5123) { elemSize = 2 }   // u16
    else if (componentType == 5125) { elemSize = 4 }   // u32
    else Fiber.abort("Gltf: index accessor componentType %(componentType) not supported (u8/u16/u32)")

    var bvIdx = a["bufferView"]
    if (!(bvIdx is Num)) Fiber.abort("Gltf: index accessor %(idx) has no bufferView")
    var bv = GltfScene.bufferViewAt_(json, bvIdx)
    var bin = GltfScene.binFromBufferView_(buffers, bv)
    var byteOffset = (a["byteOffset"] is Num ? a["byteOffset"] : 0) +
                     (bv["byteOffset"] is Num ? bv["byteOffset"] : 0)
    var count = a["count"]
    var stride = bv["byteStride"] is Num ? bv["byteStride"] : elemSize
    var out = Int32Array.new(count)
    var i = 0
    while (i < count) {
      var off = byteOffset + i * stride
      var v = 0
      if      (elemSize == 1) { v = bin[off] }
      else if (elemSize == 2) { v = Bytes_.u16LE(bin, off) }
      else                    { v = Bytes_.u32LE(bin, off) }
      out[i] = v
      i = i + 1
    }
    return out
  }

  // ---- Upload ----------------------------------------------------

  /// Build a real `@hatch:gpu` `Mesh` for every primitive that
  /// has enough data for the current `Mesh.fromArrays` layout
  /// (pos.xyz + normal.xyz + uv.xy = 32 bytes per vertex).
  /// Primitives lacking normals get zero-vector normals;
  /// primitives lacking UVs get (0, 0). The glTF spec marks
  /// normals + uvs as optional and downstream shaders / renderers
  /// tolerate the defaults.
  upload(device) {
    uploadImages_(device)
    for (m in _meshes) m.upload_(device, _materials, _imageTextures)
    // Drop the parsed image bytes and .bin buffers now that
    // everything we need is on the GPU. For Quaternius-scale assets
    // these can total 30+ MB in raw PNG bytes alone — kept around
    // they only served the upload step. Materials hold Texture
    // handles in `_imageTextures`; meshes hold their own VBO / IBO
    // handles via `Mesh.fromArrays`; spawnInto reads only metadata.
    // Callers needing hot-reload of the source bytes should keep
    // their own copy upstream.
    _imageSources = []
    _buffers      = []
  }

  // Decode + upload every resolvable image. Embedded sources slice
  // the matching buffer, external sources hand off pre-loaded bytes;
  // both flow through `Image.decode` + `device.uploadImage`. Slots
  // with no usable source stay `null` so `GltfMaterial.toGpuMaterial`
  // falls through to the renderer's 1×1 fallback.
  uploadImages_(device) {
    _imageTextures = []
    var i = 0
    while (i < _imageSources.count) {
      var src = _imageSources[i]
      if (src == null) {
        _imageTextures.add(null)
      } else {
        var bytes = null
        if (src["kind"] == "bytes") {
          bytes = src["bytes"]
        } else {
          // "buffer" — slice from the matching loaded buffer.
          var bufIdx = src["buffer"]
          var srcBuf = _buffers[bufIdx]
          var off = src["byteOffset"]
          var len = src["byteLength"]
          bytes = ByteArray.new(len)
          var k = 0
          while (k < len) {
            bytes[k] = srcBuf[off + k]
            k = k + 1
          }
        }
        var img = Image.decode(bytes)
        var fmt = (src["sRGB"] == true) ? "rgba8unorm-srgb" : "rgba8unorm"
        var tex = device.uploadImage(img, { "format": fmt })
        _imageTextures.add(tex)
      }
      i = i + 1
    }
  }

  /// Spawn the default scene into `world`. Each glTF node becomes
  /// one ECS entity carrying a `Transform`; nodes that name a
  /// mesh additionally carry a `MeshRenderer { mesh, material }`
  /// per primitive (multi-primitive meshes spawn a sibling entity
  /// per extra primitive, parented under the node entity, so the
  /// hierarchy still has one entity per glTF node from the
  /// caller's view).
  ///
  /// Returns the list of root entity ids matching the scene's
  /// `rootIndices`, in order.
  spawnInto(world) {
    var spawned = {}      // gltf node index → entity id
    var roots = []
    for (idx in _rootIndices) {
      roots.add(spawnNode_(world, idx, null, spawned))
    }
    return roots
  }

  spawnNode_(world, idx, parentEntity, spawned) {
    if (spawned.containsKey(idx)) return spawned[idx]
    var node = _nodes[idx]
    var e = world.spawn()
    spawned[idx] = e
    world.attach(e, node.transform)

    if (parentEntity != null) world.setParent(e, parentEntity)

    if (node.meshIndex != null) attachMesh_(world, e, _meshes[node.meshIndex])

    for (childIdx in node.children) {
      spawnNode_(world, childIdx, e, spawned)
    }
    return e
  }

  attachMesh_(world, parentEntity, gltfMesh) {
    var prims = gltfMesh.primitives
    if (prims.count == 0) return
    // First primitive rides on the node entity itself so simple
    // single-primitive meshes don't gain a parasitic extra entity.
    var first = prims[0]
    if (first.mesh != null) {
      world.attach(parentEntity, MeshRenderer.new(first.mesh, first.material))
    }
    var i = 1
    while (i < prims.count) {
      var p = prims[i]
      if (p.mesh != null) {
        var sub = world.spawn()
        world.attach(sub, Transform.identity)
        world.attach(sub, MeshRenderer.new(p.mesh, p.material))
        world.setParent(sub, parentEntity)
      }
      i = i + 1
    }
  }
}

/// A glTF node — name + Transform + optional mesh reference +
/// child node indices. The `transform` is a `@hatch:game`
/// `Transform`, ready to attach to an ECS entity.
class GltfNode {
  /// Internal — the scene builder hands these to the `GltfScene`
  /// constructor. User code reads them via `scene.nodes`.
  ///
  /// @param {String} name. Node's glTF `name` (empty string if
  ///   absent).
  /// @param {Transform} transform. Local TRS placement.
  /// @param {Num|Null} meshIndex. Index into `scene.meshes`, or
  ///   `null` for nodes without geometry.
  /// @param {List<Num>} children. Child node indices into
  ///   `scene.nodes`.
  construct new_(name, transform, meshIndex, children) {
    _name = name
    _transform = transform
    _meshIndex = meshIndex
    _children = children
  }
  name        { _name }
  transform   { _transform }
  meshIndex   { _meshIndex }
  children    { _children }
  toString { "GltfNode(name=%(_name), mesh=%(_meshIndex), children=%(_children.count))" }
}

/// A glTF mesh: a list of primitives + a name. Each primitive has
/// its own vertex layout and material reference; `upload_`
/// converts every primitive into a `@hatch:gpu` `Mesh`.
class GltfMesh {
  /// Internal — built by `GltfScene.buildMeshes_`.
  ///
  /// @param {String} name. The mesh's glTF `name` (empty if
  ///   absent).
  /// @param {List<GltfPrimitive>} primitives. One per glTF
  ///   primitive; each has its own vertex layout + material.
  construct new_(name, primitives) {
    _name = name
    _primitives = primitives
  }
  name        { _name }
  primitives  { _primitives }

  // Resolve material indices against the parent scene's material
  // list (+ uploaded textures) and upload each primitive to
  // the GPU.
  upload_(device, materials, textures) {
    for (p in _primitives) p.upload_(device, materials, textures)
  }
}

/// One glTF primitive — position + (optional) normal + (optional)
/// uv accessors decoded into flat Lists, plus the resolved
/// material index. `upload_` populates `mesh` and `material`
/// once a device is available.
class GltfPrimitive {
  /// Internal — built by `GltfScene.extractPrimitive_`.
  /// `mesh` and `material` start `null`; both get populated by
  /// `upload_` once a `Device` is available.
  ///
  /// @param {Float32Array} positions. Packed (x, y, z) per
  ///   vertex; never `null`.
  /// @param {Float32Array|Null} normals. Packed (x, y, z); `null`
  ///   when the glTF primitive omits `NORMAL`.
  /// @param {Float32Array|Null} uvs. Packed (u, v); `null` when
  ///   the glTF primitive omits `TEXCOORD_0`.
  /// @param {Int32Array|Null} indices. u8 / u16 / u32 widened to
  ///   i32; `null` for unindexed primitives.
  /// @param {Num|Null} materialIndex. Index into the parent
  ///   document's `materials`, or `null` to pick the default.
  construct new_(positions, normals, uvs, indices, materialIndex) {
    _positions = positions
    _normals = normals
    _uvs = uvs
    _indices = indices
    _materialIndex = materialIndex
    _mesh = null
    _material = null
  }
  positions      { _positions }
  normals        { _normals }
  uvs            { _uvs }
  indices        { _indices }
  materialIndex  { _materialIndex }
  mesh           { _mesh }
  material       { _material }

  /// Interleave (pos.xyz, normal.xyz, uv.xy) into the 32-byte
  /// vertex layout `Mesh.fromArrays` expects, then upload. Output
  /// rides on a packed `Float32Array` so the GPU upload path
  /// streams contiguous bytes; indices go to an `Int32Array` for
  /// the same reason.
  upload_(device, materials, textures) {
    if (_positions == null || _positions.count == 0) return
    var vertexCount = (_positions.count / 3).floor
    var verts = Float32Array.new(vertexCount * 8)
    var i = 0
    while (i < vertexCount) {
      var base = i * 8
      verts[base + 0] = _positions[i * 3 + 0]
      verts[base + 1] = _positions[i * 3 + 1]
      verts[base + 2] = _positions[i * 3 + 2]
      if (_normals != null && (i * 3 + 2) < _normals.count) {
        verts[base + 3] = _normals[i * 3 + 0]
        verts[base + 4] = _normals[i * 3 + 1]
        verts[base + 5] = _normals[i * 3 + 2]
      } else {
        verts[base + 3] = 0
        verts[base + 4] = 0
        verts[base + 5] = 0
      }
      if (_uvs != null && (i * 2 + 1) < _uvs.count) {
        verts[base + 6] = _uvs[i * 2 + 0]
        verts[base + 7] = _uvs[i * 2 + 1]
      } else {
        verts[base + 6] = 0
        verts[base + 7] = 0
      }
      i = i + 1
    }
    var indices = _indices
    if (indices == null) {
      // No index buffer → render as a triangle soup.
      indices = Int32Array.new(vertexCount)
      var j = 0
      while (j < vertexCount) {
        indices[j] = j
        j = j + 1
      }
    }
    _mesh = Mesh.fromArrays(device, verts, indices)
    _material = pickMaterial_(materials, textures)
  }

  pickMaterial_(materials, textures) {
    if (_materialIndex == null) return defaultMaterial_()
    if (_materialIndex >= materials.count) return defaultMaterial_()
    return materials[_materialIndex].toGpuMaterial(textures)
  }

  defaultMaterial_() {
    return Material.new(Vec4.new(0.8, 0.8, 0.85, 1.0))
  }
}

/// Parsed glTF material. Holds every factor + texture-index
/// reference the spec defines for the metallic-roughness
/// workflow. `toGpuMaterial(textures)` resolves the texture
/// indices into a fully-textured `@hatch:gpu.Material`.
class GltfMaterial {
  /// Internal — built by `GltfScene.buildMaterials_`.
  ///
  /// @param {String} name. Material's glTF `name` (empty if
  ///   absent).
  /// @param {Vec4} baseColor. `pbrMetallicRoughness.baseColorFactor`
  ///   (defaults to `(1, 1, 1, 1)` when missing).
  /// @param {Num} metallic. `metallicFactor` (defaults to `1.0`
  ///   when missing per glTF spec).
  /// @param {Num} roughness. `roughnessFactor` (defaults to
  ///   `1.0` when missing per glTF spec).
  /// @param {Num|Null} albedoImageIndex. Resolved image index for
  ///   `pbrMetallicRoughness.baseColorTexture`, or `null`.
  /// @param {Num|Null} mrImageIndex. Image index for
  ///   `pbrMetallicRoughness.metallicRoughnessTexture`, or `null`.
  /// @param {Num|Null} normalImageIndex. Image index for the
  ///   normal map, or `null`.
  /// @param {Num} normalScale. `normalTexture.scale` (defaults
  ///   to `1.0`).
  /// @param {Num|Null} occlusionImageIndex. Image index for the
  ///   AO map, or `null`.
  /// @param {Num} occlusionStrength. `occlusionTexture.strength`.
  /// @param {Num|Null} emissiveImageIndex. Image index for the
  ///   emissive map, or `null`.
  /// @param {Vec4} emissiveColor. `emissiveFactor` lifted to a
  ///   `Vec4` (alpha = 1).
  /// @param {String} alphaMode. `"opaque"` / `"mask"` / `"blend"`.
  /// @param {Num} alphaCutoff. Per glTF spec.
  /// @param {Bool} doubleSided. Per glTF spec.
  construct new_(name, baseColor, metallic, roughness, albedoImageIndex, mrImageIndex, normalImageIndex, normalScale, occlusionImageIndex, occlusionStrength, emissiveImageIndex, emissiveColor, alphaMode, alphaCutoff, doubleSided) {
    _name = name
    _baseColor = baseColor
    _metallic = metallic
    _roughness = roughness
    _albedoImg    = albedoImageIndex
    _mrImg        = mrImageIndex
    _normalImg    = normalImageIndex
    _normalScale  = normalScale
    _occlusionImg = occlusionImageIndex
    _occlusionStrength = occlusionStrength
    _emissiveImg  = emissiveImageIndex
    _emissiveColor = emissiveColor
    _alphaMode = alphaMode
    _alphaCutoff = alphaCutoff
    _doubleSided = doubleSided
  }

  name              { _name }
  baseColor         { _baseColor }
  metallic          { _metallic }
  roughness         { _roughness }
  albedoImageIndex     { _albedoImg }
  mrImageIndex         { _mrImg }
  normalImageIndex     { _normalImg }
  normalScale          { _normalScale }
  occlusionImageIndex  { _occlusionImg }
  occlusionStrength    { _occlusionStrength }
  emissiveImageIndex   { _emissiveImg }
  emissiveColor        { _emissiveColor }
  alphaMode            { _alphaMode }
  alphaCutoff          { _alphaCutoff }
  doubleSided          { _doubleSided }

  /// Resolve the parsed factors + texture indices into a fully
  /// configured `@hatch:gpu.Material`. `textures` is the parent
  /// scene's `_imageTextures` list (one `Texture` per glTF image
  /// after `upload`); `null` entries fall through to the
  /// renderer's 1×1 fallback.
  ///
  /// @param {List<Texture|Null>} textures
  /// @returns {Material}
  toGpuMaterial(textures) {
    var m = Material.new()
    m.albedoColor      = _baseColor
    m.metallicFactor   = _metallic
    m.roughnessFactor  = _roughness
    m.normalScale      = _normalScale
    m.occlusionStrength = _occlusionStrength
    m.emissiveColor    = _emissiveColor
    m.alphaMode        = _alphaMode
    m.alphaCutoff      = _alphaCutoff
    m.doubleSided      = _doubleSided

    if (_albedoImg    != null) m.albedoTexture            = textures[_albedoImg]
    if (_mrImg        != null) m.metallicRoughnessTexture = textures[_mrImg]
    if (_normalImg    != null) m.normalTexture            = textures[_normalImg]
    if (_occlusionImg != null) m.occlusionTexture         = textures[_occlusionImg]
    if (_emissiveImg  != null) m.emissiveTexture          = textures[_emissiveImg]
    return m
  }
}
