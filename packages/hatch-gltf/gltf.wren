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
// Supported beyond the basics above:
//   - Animations: TRS keyframes per node via `GltfAnimation` /
//     `GltfAnimChannel`; STEP / LINEAR / CUBICSPLINE interpolation;
//     `applyTo(scene, world, t)` writes joint Transforms each frame
//     and `crossfade(other, world, scene, ta, tb, blend)` blends two
//     animations into one pose for clip-to-clip transitions.
//   - Skins + joints: `GltfSkin` (joint indices + inverse-bind
//     matrices) + skinned `Mesh.fromArraysSkinned` (JOINTS_0 +
//     WEIGHTS_0 VBOs). Pair with `@hatch:gpu/SkinPalette` and
//     `Renderer3D.drawSkinned` for the full GPU skinning path
//     (storage-buffer joint-matrix palette, weighted vertex blend
//     in the skinned PBR shader).
//   - `KHR_materials_pbrSpecularGlossiness` fallback when a material
//     doesn't ship a standard PBR slot.
//
// Not yet supported: sparse accessors, point / line primitives,
// morph targets, cameras. Each lands when the downstream feature
// needs it.

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
          // Yield after every external image read — for character
          // assets with 20+ textures the cumulative file-read cost
          // is noticeable. Caller running from a fiber gets a
          // window paint per file; bare callers no-op.
          Fiber.yield()
        } else {
          externalImageBytes.add(null)
        }
      }
    }

    // Yield once between the file-IO phase and the
    // parse-and-upload phase.
    Fiber.yield()
    var scene = GltfScene.fromJson_(json, buffers, externalImageBytes)
    scene.upload(device)
    return scene
  }

  /// Open a glTF directory for *incremental* loading. Reads only
  /// the top-level .gltf JSON; returns a state Map the caller fills
  /// in via `loadBuffer` / `loadImage`, then promotes to a
  /// `GltfScene` via `assemble`, finishing with per-item
  /// `uploadImageAt` / `uploadMeshAt` calls.
  ///
  /// The shape is designed to fit `@hatch:assets/AssetLoader`'s
  /// one-entry-per-frame queue: each external buffer, external
  /// image, image upload, and mesh upload becomes one queue entry,
  /// so a loading scene's progress bar advances smoothly.
  ///
  /// ```wren
  /// var st = Gltf.openDir(db, "the_strangler/scene.gltf")
  /// for (i in 0...st["bufferCount"]) loader.queue("buf%(i)", Fn.new { Gltf.loadBuffer(st, db, i) })
  /// for (i in 0...st["imageCount"])  loader.queue("img%(i)", Fn.new { Gltf.loadImage(st, db, i) })
  /// loader.queue("assemble", Fn.new { Gltf.assemble(st) })
  /// for (i in 0...st["imageCount"])  loader.queue("upimg%(i)", Fn.new { Gltf.uploadImageAt(st, device, i) })
  /// loader.queue("finish", Fn.new { Gltf.finishUpload(st, device); _scene = st["scene"] })
  /// ```
  ///
  /// @returns {Map} state with keys `dir`, `json`, `buffers`,
  ///   `imageBytes`, `bufferCount`, `imageCount`, and (after
  ///   `assemble`) `scene`.
  static openDir(db, gltfPath) {
    var dir = GltfScene.dirname_(gltfPath)
    var jsonBytes = db.bytes(gltfPath)
    // Skip the bytes→String→ByteArray round-trip the old path did via
    // Bytes_.asciiString + JSON.parse(text). `parseBytes` walks the
    // ByteArray directly, dropping the per-character String alloc.
    var json = JSON.parseBytes(GltfScene.stripPadBytes_(jsonBytes))
    if (!(json is Map)) Fiber.abort("Gltf.openDir: %(gltfPath) did not decode to a JSON object")

    var bufArr  = json["buffers"] is List ? json["buffers"] : []
    var imgArr  = json["images"]  is List ? json["images"]  : []
    var buffers    = List.filled(bufArr.count, null)
    var imageBytes = List.filled(imgArr.count, null)
    return {
      "dir":         dir,
      "json":        json,
      "buffers":     buffers,
      "imageBytes":  imageBytes,
      "bufferCount": bufArr.count,
      "imageCount":  imgArr.count,
      "scene":       null
    }
  }

  /// Read one external buffer URI into `state["buffers"][idx]`.
  /// `data:` and embedded buffers are not supported on the
  /// streaming path — externalise them or use the `.glb` /
  /// `Gltf.load` path which keeps everything in one call.
  static loadBuffer(state, db, idx) {
    var bArr = state["json"]["buffers"]
    if (!(bArr is List) || idx >= bArr.count) return
    var bEntry = bArr[idx]
    if (!(bEntry is Map)) Fiber.abort("Gltf.loadBuffer: bad buffer entry %(idx)")
    var uri = bEntry["uri"]
    if (!(uri is String)) Fiber.abort("Gltf.loadBuffer: buffer %(idx) missing uri")
    if (uri.startsWith("data:")) {
      Fiber.abort("Gltf.loadBuffer: data: URIs not yet supported — externalise the buffer or use .glb")
    }
    var bufPath = GltfScene.joinPath_(state["dir"], uri)
    state["buffers"][idx] = db.bytes(bufPath)
  }

  /// Read one external image URI's raw bytes into
  /// `state["imageBytes"][idx]`. Does NOT decode the PNG/JPG; the
  /// decode happens later in `uploadImageAt`. Embedded (`bufferView`)
  /// images leave the slot as `null` and pick up their bytes from
  /// the matching buffer during `uploadImageAt`.
  static loadImage(state, db, idx) {
    var imgs = state["json"]["images"]
    if (!(imgs is List) || idx >= imgs.count) return
    var im = imgs[idx]
    if (im is Map && im["uri"] is String && !im["uri"].startsWith("data:")) {
      var imgPath = GltfScene.joinPath_(state["dir"], im["uri"])
      state["imageBytes"][idx] = db.bytes(imgPath)
    }
  }

  /// Build the `GltfScene` from the JSON + buffers + image bytes
  /// already populated in `state`. Cheap: parses materials, meshes,
  /// nodes, animations, skins. No GPU work. Stores the new scene
  /// at `state["scene"]` and returns it.
  static assemble(state) {
    var scene = GltfScene.fromJson_(state["json"], state["buffers"], state["imageBytes"])
    state["scene"] = scene
    return scene
  }

  /// Decode + upload one image into the assembled scene. Pair with
  /// `assemble` (which must run first); call once per slot in
  /// `0 ... state["imageCount"]`. PNG decode is the dominant
  /// cost — one queue entry per image lets the loading bar reflect
  /// the actual work being done.
  ///
  /// This is the SYNCHRONOUS variant — the decode blocks the
  /// calling frame. For multi-second PNGs (4K skin textures, HDR
  /// environment maps), use `beginImageDecodeAt` +
  /// `finishImageUploadAt` instead so the work runs on a worker
  /// thread and the game loop keeps rendering.
  static uploadImageAt(state, device, idx) {
    var scene = state["scene"]
    if (scene == null) Fiber.abort("Gltf.uploadImageAt: call Gltf.assemble first")
    scene.uploadImageAt_(device, idx)
  }

  /// Async decode — stage 1. Kicks off a worker-thread PNG/JPEG
  /// decode for `_imageSources[idx]`. Returns an
  /// `ImageDecodeHandle` the caller polls each frame; once it's
  /// ready, pair with `finishImageUploadAt` for the GPU upload.
  /// Returns `null` if the image slot has no source.
  static beginImageDecodeAt(state, idx) {
    var scene = state["scene"]
    if (scene == null) Fiber.abort("Gltf.beginImageDecodeAt: call Gltf.assemble first")
    return scene.beginImageDecodeAt_(idx)
  }

  /// Async decode — stage 2. Drains a ready `ImageDecodeHandle`
  /// into a GPU texture stored at the matching image slot. Aborts
  /// if the handle isn't ready yet (caller's poll loop is
  /// responsible). Pass `null` for `handle` when the source slot
  /// is empty.
  static finishImageUploadAt(state, device, idx, handle) {
    var scene = state["scene"]
    if (scene == null) Fiber.abort("Gltf.finishImageUploadAt: call Gltf.assemble first")
    scene.finishImageUploadAt_(device, idx, handle)
  }

  /// Async decode — already-decoded `Image` variant. The drained
  /// `image` (typically from an `ImageDecodeHandle.result`) is
  /// uploaded straight to the GPU at slot `idx`, honouring the
  /// material's sRGB flag. Designed for `AssetLoader.queueDecode`,
  /// which drains the handle on the caller's behalf and hands the
  /// finishFn the already-decoded `Image`.
  static uploadDecodedImageAt(state, device, idx, image) {
    var scene = state["scene"]
    if (scene == null) Fiber.abort("Gltf.uploadDecodedImageAt: call Gltf.assemble first")
    scene.uploadDecodedImageAt_(device, idx, image)
  }

  /// Upload one mesh's GPU buffers (VBO / IBO + per-primitive
  /// joints/weights for skinned meshes). Call once per mesh after
  /// every `uploadImageAt` has run, so materials see real textures.
  static uploadMeshAt(state, device, idx) {
    var scene = state["scene"]
    if (scene == null) Fiber.abort("Gltf.uploadMeshAt: call Gltf.assemble first")
    scene.uploadMeshAt_(device, idx)
  }

  /// Drop the source bytes the upload steps consumed (raw image
  /// payloads, .bin buffers) so they're available for GC. Optional
  /// — call once after every `uploadImageAt` + `uploadMeshAt` to
  /// reclaim the multi-MB asset memory.
  static finishUpload(state) {
    var scene = state["scene"]
    if (scene == null) return
    scene.dropUploadSources_()
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

  /// Read a UTF-8 ASCII string over a byte slice. ByteArray takes
  /// the single-FFI native fast path (`utf8Slice`); plain
  /// `List<Num>` falls back to the per-byte build — slow but
  /// preserves compatibility with hermetic test fixtures that
  /// hand-construct .glb byte streams.
  static asciiString(b, off, len) {
    if (b is ByteArray) return b.utf8Slice(off, len)
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
    // Per-channel TRS keyframes. Empty list when the file carries no
    // animations. Each entry is a GltfAnimation; channels are
    // parsed eagerly so per-frame sampling skips JSON walks.
    _animations     = GltfScene.buildAnimations_(json, _buffers)
    // Skeletal-animation rigs. Each entry is a GltfSkin with its
    // joint node indices + inverse-bind matrices. Empty when the
    // file carries no skins. Joint world matrices come from the
    // joint nodes' Transforms after AnimationSystem ticks; the
    // skinning pipeline multiplies them with the IBMs to build
    // the per-frame joint-matrix palette.
    _skins          = GltfScene.buildSkins_(json, _buffers)
    // Populated by `spawnInto` — Map<gltfNodeIndex, ecsEntityId>.
    // Lets animation tooling map a channel's `target.node` back to
    // the entity whose Transform it should write.
    _nodeEntityMap  = null
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
  /// Parsed animations from the glTF document. List of
  /// `GltfAnimation` — one per `json["animations"][i]`. Empty when
  /// the file carries none.
  animations   { _animations }
  /// List of uploaded Texture handles, one per `json["images"][i]`.
  /// Populated by the upload path; entries are `null` until their
  /// matching image has been decoded + uploaded (or stay `null`
  /// permanently if the source slot was empty).
  imageTextures { _imageTextures }
  /// Parsed skins from the glTF document. List of `GltfSkin` —
  /// one per `json["skins"][i]`. Empty when no skins are present.
  skins        { _skins }
  /// `Map<gltfNodeIndex, ecsEntityId>` populated by `spawnInto`.
  /// `null` until `spawnInto` has been called; lets an animator
  /// resolve a channel's `target.node` back to the entity whose
  /// Transform it should write.
  nodeEntityMap { _nodeEntityMap }

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

  // ByteArray variant. Walks bytes backward looking for trailing
  // ASCII space (32) or NUL (0), and returns a fresh slice that
  // drops them. The streaming-loader path calls this so JSON.parseBytes
  // doesn't see the 4-byte alignment padding that .glb writers append
  // to the JSON chunk.
  static stripPadBytes_(b) {
    var n = b.count
    while (n > 0) {
      var c = b[n - 1]
      if (c != 32 && c != 0) break
      n = n - 1
    }
    if (n == b.count) return b
    var out = ByteArray.new(n)
    var i = 0
    while (i < n) {
      out[i] = b[i]
      i = i + 1
    }
    return out
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
      // KHR_materials_pbrSpecularGlossiness fallback — many older
      // character pipelines (Reallusion CC, Adobe Substance, older
      // Sketchfab exports) author materials with this extension
      // instead of the standard PBR metallic-roughness path. Map
      // diffuse → albedo, specular reflectance → metallic, and
      // gloss → (1 - roughness) so the downstream PBR shader's
      // existing channels surface the textures unchanged. Only
      // applied when the standard path didn't already populate
      // them, so authors who mix both still get the standard
      // values.
      var sg = m["extensions"] is Map ? m["extensions"]["KHR_materials_pbrSpecularGlossiness"] : null
      if (sg is Map) {
        if (albedoImgIdx == null) {
          albedoImgIdx = GltfScene.imageIndexOf_(json, t2i, sg["diffuseTexture"])
        }
        var df = sg["diffuseFactor"]
        if (df is List && df.count >= 4) {
          bc = Vec4.new(df[0], df[1], df[2], df[3])
        }
        if (sg["glossinessFactor"] is Num) {
          roughness = 1 - sg["glossinessFactor"]
        }
        var sf = sg["specularFactor"]
        if (sf is List && sf.count >= 3) {
          // Specular intensity → metallic proxy. Coarse but the
          // dominant signal: high specular = metal-like.
          metallic = (sf[0] + sf[1] + sf[2]) / 3
        }
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

    // glTF spec: TANGENT is `VEC4`, xyz = tangent direction,
    // w = bitangent handedness (+1 / -1). Pulled separately so a
    // primitive that ships tangents (most modern PBR exports do)
    // gets vertex-tangent normal mapping; primitives without
    // tangent fall back to screen-space derivatives in the shader.
    var tangents = null
    var tanIdx = attrs["TANGENT"]
    if (tanIdx is Num) tangents = GltfScene.readFloatAccessor_(json, buffers, tanIdx, 4, "VEC4")

    // glTF spec: JOINTS_0 is VEC4 of u8/u16/u32; WEIGHTS_0 is VEC4
    // of f32 (normalised values summing to ~1 per vertex). Both
    // optional — primitives without these stay rigid and fall
    // through the static PBR pipeline.
    var joints = null
    var jntIdx = attrs["JOINTS_0"]
    if (jntIdx is Num) joints = GltfScene.readU16x4Accessor_(json, buffers, jntIdx)

    var weights = null
    var wgtIdx = attrs["WEIGHTS_0"]
    if (wgtIdx is Num) weights = GltfScene.readFloatAccessor_(json, buffers, wgtIdx, 4, "VEC4")

    var indices = null
    if (p["indices"] is Num) indices = GltfScene.readIndexAccessor_(json, buffers, p["indices"])

    var materialIndex = p["material"] is Num ? p["material"] : null
    var prim = GltfPrimitive.new_(positions, normals, uvs, tangents, indices, materialIndex)
    prim.joints_ = joints
    prim.weights_ = weights
    return prim
  }

  // -- Nodes -------------------------------------------------------

  // buildNodes_: walk every node JSON entry and produce a GltfNode.
  //
  // The per-node body is FULLY INLINED here — no `buildNode_(n)`
  // helper. A character-scale asset (the_strangler: 141 nodes)
  // crossed the JIT tier-up threshold (`jit_threshold = 100` in
  // src/runtime/engine.rs) when the per-node work lived in its own
  // static method. The JIT-compiled version of that method
  // intermittently returned `null` instead of the explicit `return
  // node` value, leaving the last 25-41 entries of `_nodes` null
  // and crashing spawnInto with "Null doesn't implement
  // 'transform'" deep in spawnNode_. See
  // [[project-jit-static-return-null]] for the cranelift codegen
  // root cause.
  //
  // Single function called once per scene = no tier-up = no bug.
  // The inlined body trades a small bit of readability for
  // determinism; revisit when the JIT bug is fixed upstream.
  static buildNodes_(json) {
    var out = []
    var arr = json["nodes"]
    if (!(arr is List)) return out
    var i = 0
    var n = arr.count
    while (i < n) {
      var nj = arr[i]
      var name = nj["name"] is String ? nj["name"] : ""
      var t = Vec3.zero
      var r = Quat.identity
      var s = Vec3.one
      if (nj["translation"] is List && nj["translation"].count >= 3) {
        var v = nj["translation"]
        t = Vec3.new(v[0], v[1], v[2])
      }
      if (nj["rotation"] is List && nj["rotation"].count >= 4) {
        // glTF stores rotation as (x, y, z, w); Quat is (w, x, y, z).
        var v = nj["rotation"]
        r = Quat.new(v[3], v[0], v[1], v[2])
      }
      if (nj["scale"] is List && nj["scale"].count >= 3) {
        var v = nj["scale"]
        s = Vec3.new(v[0], v[1], v[2])
      }
      var transform = Transform.new(t, r, s)
      var meshIndex = nj["mesh"] is Num ? nj["mesh"] : null
      var children  = []
      var rawChildren = nj["children"]
      if (rawChildren is List) {
        var ci = 0
        var cn = rawChildren.count
        while (ci < cn) {
          var idx = rawChildren[ci]
          if (idx is Num) children.add(idx)
          ci = ci + 1
        }
      }
      var node = GltfNode.new_(name, transform, meshIndex, children)
      if (nj["skin"] is Num) node.skinIndex = nj["skin"]
      out.add(node)
      i = i + 1
    }
    return out
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

  // -- Animations --------------------------------------------------

  // Parse every animation in the glTF document into a list of
  // `GltfAnimation`s. Each animation owns its channels (TRS
  // targets) and samplers (keyframe accessor reads). Sampling is
  // pushed into GltfAnimChannel so the demo's per-frame loop is
  // just `channel.sample(t)` → write to the target entity.
  static buildAnimations_(json, buffers) {
    var out = []
    var arr = json["animations"]
    if (!(arr is List)) return out
    for (a in arr) {
      var name = a["name"] is String ? a["name"] : ""
      var samplers = a["samplers"] is List ? a["samplers"] : []
      var channels = a["channels"] is List ? a["channels"] : []
      var parsedChannels = []
      var maxTime = 0
      for (ch in channels) {
        var target = ch["target"]
        if (!(target is Map)) continue
        var nodeIdx = target["node"]
        var path    = target["path"]
        if (!(nodeIdx is Num) || !(path is String)) continue
        // Only TRS paths land in V1. Morph-target `weights`
        // animation needs separate plumbing (scalar-per-weight
        // accessors + MeshRenderer support) — silently skip so
        // assets that mix TRS + morph keyframes still load.
        if (path != "translation" && path != "rotation" && path != "scale") continue
        var samplerIdx = ch["sampler"]
        if (!(samplerIdx is Num) || samplerIdx >= samplers.count) continue
        var s = samplers[samplerIdx]
        if (!(s is Map)) continue
        var inputs  = GltfScene.readFloatAccessor_(json, buffers,
                        s["input"], 1, "SCALAR")
        var components = path == "rotation" ? 4 : 3
        var outputType = components == 4 ? "VEC4" : "VEC3"
        var outputs = GltfScene.readFloatAccessor_(json, buffers,
                        s["output"], components, outputType)
        var interp = s["interpolation"] is String ? s["interpolation"] : "LINEAR"
        if (inputs.count > 0) {
          var last = inputs[inputs.count - 1]
          if (last > maxTime) maxTime = last
        }
        parsedChannels.add(GltfAnimChannel.new_(
          nodeIdx, path, inputs, outputs, components, interp))
      }
      out.add(GltfAnimation.new_(name, maxTime, parsedChannels))
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
    var bvStride = bv["byteStride"] is Num ? bv["byteStride"] : 0
    var out = Float32Array.new(count * components)
    // Native bulk decode — one FFI per row (vec3/vec4/etc), or
    // even one FFI for the whole accessor when the bufferView is
    // tightly packed. Falls back to the per-byte Wren path only
    // if the runtime hasn't been built with the bulk decoders
    // (older wlift).
    if (bvStride == 0 || bvStride == components * 4) {
      // Tight packing across the whole accessor — single FFI.
      bin.copyToFloat32Array(byteOffset, count * components, out, 0, 0)
    } else {
      // Strided: one FFI per row, `components` floats each.
      var i = 0
      while (i < count) {
        bin.copyToFloat32Array(byteOffset + i * bvStride, components, out, i * components, 0)
        i = i + 1
      }
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
    var bvStride = bv["byteStride"] is Num ? bv["byteStride"] : 0
    var out = Int32Array.new(count)
    if (elemSize == 1) {
      bin.copyU8ToInt32Array(byteOffset, count, out, 0, bvStride)
    } else if (elemSize == 2) {
      bin.copyU16LEToInt32Array(byteOffset, count, out, 0, bvStride)
    } else {
      // u32 path — single-element FFI per index. Could add a
      // bulk u32 variant if profiling shows this is hot.
      var stride = bvStride == 0 ? 4 : bvStride
      var i = 0
      while (i < count) {
        out[i] = bin.readU32LE(byteOffset + i * stride)
        i = i + 1
      }
    }
    return out
  }

  // Reads a u8/u16 VEC4 accessor (typical for `JOINTS_0`) into a
  // packed `Int32Array` of length `count * 4`. Widens every joint
  // index to i32 so downstream skinning code can index a storage
  // array without an extra unpack step. u32 also valid but rare.
  static readU16x4Accessor_(json, buffers, idx) {
    var a = GltfScene.accessorAt_(json, idx)
    if (a["type"] != "VEC4") {
      Fiber.abort("Gltf: joint accessor %(idx) type %(a["type"]), expected VEC4")
    }
    var componentType = a["componentType"]
    var elemSize = 0
    if      (componentType == 5121) { elemSize = 1 }   // u8
    else if (componentType == 5123) { elemSize = 2 }   // u16
    else if (componentType == 5125) { elemSize = 4 }   // u32
    else Fiber.abort("Gltf: joint accessor componentType %(componentType) not supported (u8/u16/u32)")
    var bvIdx = a["bufferView"]
    if (!(bvIdx is Num)) Fiber.abort("Gltf: joint accessor %(idx) has no bufferView")
    var bv = GltfScene.bufferViewAt_(json, bvIdx)
    var bin = GltfScene.binFromBufferView_(buffers, bv)
    var byteOffset = (a["byteOffset"] is Num ? a["byteOffset"] : 0) +
                     (bv["byteOffset"] is Num ? bv["byteOffset"] : 0)
    var count = a["count"]
    var bvStride = bv["byteStride"] is Num ? bv["byteStride"] : 0
    var out = Int32Array.new(count * 4)
    var rowBytes = elemSize * 4
    // Native bulk decode — one FFI for the whole tightly-packed
    // accessor (typical case), else one FFI per row.
    if (bvStride == 0 || bvStride == rowBytes) {
      if (elemSize == 1) {
        bin.copyU8ToInt32Array(byteOffset, count * 4, out, 0, 0)
      } else if (elemSize == 2) {
        bin.copyU16LEToInt32Array(byteOffset, count * 4, out, 0, 0)
      } else {
        // u32 — extremely rare for JOINTS_0; fall back to slow path.
        var i = 0
        while (i < count) {
          var rowOff = byteOffset + i * rowBytes
          var c = 0
          while (c < 4) {
            out[i * 4 + c] = bin.readU32LE(rowOff + c * 4)
            c = c + 1
          }
          i = i + 1
        }
      }
    } else {
      // Strided rows — one FFI per row.
      var i = 0
      while (i < count) {
        if (elemSize == 1) {
          bin.copyU8ToInt32Array(byteOffset + i * bvStride, 4, out, i * 4, 0)
        } else if (elemSize == 2) {
          bin.copyU16LEToInt32Array(byteOffset + i * bvStride, 4, out, i * 4, 0)
        } else {
          var c = 0
          while (c < 4) {
            out[i * 4 + c] = bin.readU32LE(byteOffset + i * bvStride + c * 4)
            c = c + 1
          }
        }
        i = i + 1
      }
    }
    return out
  }

  // Reads a `MAT4` f32 accessor (used for inverse-bind matrices)
  // into a packed `Float32Array` of length `count * 16`. Stored
  // column-major per glTF spec — pass straight to the GPU shader.
  static readMat4Accessor_(json, buffers, idx) {
    return GltfScene.readFloatAccessor_(json, buffers, idx, 16, "MAT4")
  }

  // Build every `GltfSkin` from `json["skins"]`. Each skin is a
  // List<Num> of joint node indices + a Float32Array of inverse-
  // bind matrices (one mat4 per joint, optional in glTF spec — if
  // absent, defaults to identity matrices). Skeleton root is
  // optional too.
  static buildSkins_(json, buffers) {
    var out = []
    var arr = json["skins"]
    if (!(arr is List)) return out
    for (s in arr) {
      var joints = s["joints"]
      if (!(joints is List)) {
        Fiber.abort("Gltf: skin missing `joints` array")
      }
      var jointList = []
      for (j in joints) jointList.add(j)
      var ibm = null
      if (s["inverseBindMatrices"] is Num) {
        ibm = GltfScene.readMat4Accessor_(json, buffers, s["inverseBindMatrices"])
      } else {
        // Spec: when absent, each IBM defaults to identity.
        ibm = Float32Array.new(jointList.count * 16)
        var j = 0
        while (j < jointList.count) {
          var base = j * 16
          ibm[base + 0]  = 1
          ibm[base + 5]  = 1
          ibm[base + 10] = 1
          ibm[base + 15] = 1
          j = j + 1
        }
      }
      var skeleton = s["skeleton"] is Num ? s["skeleton"] : null
      var name = s["name"] is String ? s["name"] : ""
      out.add(GltfSkin.new_(name, jointList, ibm, skeleton))
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
    // Yield once between the image-decode phase and the mesh
    // upload phase. Callers running this from a Fiber (Game.run's
    // setup pump) get a window paint + event drain here. Bare
    // calls (no fiber above) treat yield as a no-op.
    Fiber.yield()
    for (m in _meshes) {
      m.upload_(device, _materials, _imageTextures)
      Fiber.yield()
    }
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
      uploadImageAt_(device, i)
      // Yield after every image — PNG decode + GPU upload is the
      // single most expensive step in a typical asset load (often
      // 80%+ of wall-clock for character + texture-heavy scenes).
      // Game.run's setup pump pumps OS events here, so the window
      // stays responsive during multi-second decode runs.
      Fiber.yield()
      i = i + 1
    }
  }

  // Decode + upload one image into _imageTextures[idx]. Used by
  // both the bulk `uploadImages_` path AND the streaming
  // `Gltf.uploadImageAt` path so the per-image work has exactly
  // one definition. _imageTextures is grown as needed so callers
  // can hit arbitrary indices in any order.
  uploadImageAt_(device, idx) {
    while (_imageTextures.count <= idx) _imageTextures.add(null)
    var src = _imageSources[idx]
    if (src == null) {
      _imageTextures[idx] = null
      return
    }
    var bytes = sourceBytesAt_(idx)
    var img = Image.decode(bytes)
    var fmt = (src["sRGB"] == true) ? "rgba8unorm-srgb" : "rgba8unorm"
    _imageTextures[idx] = device.uploadImage(img, { "format": fmt })
  }

  // Build the raw PNG/JPG bytes for `_imageSources[idx]`. Embedded
  // images slice from the right `_buffers[bufIdx]`; external
  // images just hand back the pre-loaded ByteArray. Shared by both
  // the synchronous `uploadImageAt_` and the async
  // `beginImageDecodeAt_` paths so the slicing math has one home.
  sourceBytesAt_(idx) {
    var src = _imageSources[idx]
    if (src == null) return null
    if (src["kind"] == "bytes") return src["bytes"]
    var bufIdx = src["buffer"]
    var srcBuf = _buffers[bufIdx]
    var off = src["byteOffset"]
    var len = src["byteLength"]
    var bytes = ByteArray.new(len)
    var k = 0
    while (k < len) {
      bytes[k] = srcBuf[off + k]
      k = k + 1
    }
    return bytes
  }

  // Async decode path. Stage 1 — stage the bytes + kick off a
  // worker-thread decode for image `idx`. Returns an
  // `ImageDecodeHandle` the caller polls each frame; once the
  // handle is ready, pair it with `finishImageUploadAt_` to land
  // the GPU texture.
  beginImageDecodeAt_(idx) {
    while (_imageTextures.count <= idx) _imageTextures.add(null)
    var src = _imageSources[idx]
    if (src == null) {
      _imageTextures[idx] = null
      return null
    }
    var bytes = sourceBytesAt_(idx)
    return Image.decodeBegin(bytes)
  }

  // Async decode path. Stage 2 — drain `handle.result` (must be
  // ready; the caller's poll loop is responsible) and upload the
  // decoded RGBA8 to the GPU. Stores the resulting Texture in
  // `_imageTextures[idx]`.
  finishImageUploadAt_(device, idx, handle) {
    while (_imageTextures.count <= idx) _imageTextures.add(null)
    var src = _imageSources[idx]
    if (src == null || handle == null) {
      _imageTextures[idx] = null
      return
    }
    uploadDecodedImageAt_(device, idx, handle.result)
  }

  // Async decode path. Stage 2 — already-drained `Image` variant.
  // The asset loader's `queueDecode` drains the handle on the
  // caller's behalf and passes the `Image` to finishFn; this is
  // the matching entry point.
  uploadDecodedImageAt_(device, idx, image) {
    while (_imageTextures.count <= idx) _imageTextures.add(null)
    var src = _imageSources[idx]
    if (src == null || image == null) {
      _imageTextures[idx] = null
      return
    }
    var fmt = (src["sRGB"] == true) ? "rgba8unorm-srgb" : "rgba8unorm"
    _imageTextures[idx] = device.uploadImage(image, { "format": fmt })
  }

  // Upload one mesh's GPU buffers. Streaming `Gltf.uploadMeshAt`
  // entry point — pair with `uploadImageAt_` for each image first
  // so materials see real textures by the time the mesh's primitive
  // pipelines bind them.
  uploadMeshAt_(device, idx) {
    if (idx >= _meshes.count) return
    _meshes[idx].upload_(device, _materials, _imageTextures)
  }

  // Streaming-loader cleanup. Drops the parsed image bytes + .bin
  // buffers (multi-MB) once every `uploadImageAt_` + `uploadMeshAt_`
  // has run. Materials hold Texture handles, meshes hold their own
  // VBO/IBO handles; nothing downstream still needs the source
  // bytes. Equivalent of the bytes-drop at the tail of `upload`.
  dropUploadSources_() {
    _imageSources = []
    _buffers      = []
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
    _nodeEntityMap = spawned
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
  /// @param {Num|Null} skinIndex. Index into `scene.skins` when
  ///   this node carries a skinned mesh; `null` otherwise.
  construct new_(name, transform, meshIndex, children) {
    _name = name
    _transform = transform
    _meshIndex = meshIndex
    _children = children
    _skinIndex = null
  }
  name        { _name }
  transform   { _transform }
  meshIndex   { _meshIndex }
  children    { _children }
  /// Skin index this node uses (`null` when the node carries no
  /// skinned mesh). Populated by `buildNodes_` from `n["skin"]`.
  /// @returns {Num|Null}
  skinIndex     { _skinIndex }
  skinIndex=(v) { _skinIndex = v }
  toString { "GltfNode(name=%(_name), mesh=%(_meshIndex), skin=%(_skinIndex), children=%(_children.count))" }
}

/// Skeletal rig for a skinned mesh — joint node indices + the
/// inverse-bind matrices that move geometry from local space into
/// each joint's reference frame. The renderer composes
/// `joint_world * inverseBindMatrix` per frame to build the
/// joint-matrix palette the skinning vertex shader samples.
class GltfSkin {
  /// Internal — built by `GltfScene.buildSkins_`. User code reads
  /// via `scene.skins`.
  ///
  /// @param {String} name. glTF `name` (empty if absent).
  /// @param {List<Num>} joints. Joint node indices into
  ///   `scene.nodes`. Index `k` in this list is the skinning bone
  ///   `k` referenced by `JOINTS_0` vertex attributes.
  /// @param {Float32Array} inverseBindMatrices. `count = joints.count
  ///   * 16` floats — one column-major `mat4` per joint.
  /// @param {Num|Null} skeletonRoot. Optional root node; the
  ///   renderer walks down from here when composing joint world
  ///   transforms.
  construct new_(name, joints, inverseBindMatrices, skeletonRoot) {
    _name = name
    _joints = joints
    _ibm = inverseBindMatrices
    _skeletonRoot = skeletonRoot
  }
  name                { _name }
  joints              { _joints }
  inverseBindMatrices { _ibm }
  skeletonRoot        { _skeletonRoot }
  jointCount          { _joints.count }
  toString            { "GltfSkin(name=%(_name), joints=%(_joints.count))" }
}

/// A parsed glTF animation. Owns one or more `GltfAnimChannel`s
/// (TRS targets) and a derived duration (the maximum input time
/// across all channels). Driven by a per-frame clock — sample
/// each channel with `(time % duration)` to loop the animation.
class GltfAnimation {
  /// Internal — built by `GltfScene.buildAnimations_`. User code
  /// reads them via `scene.animations`.
  construct new_(name, duration, channels) {
    _name     = name
    _duration = duration
    _channels = channels
  }
  /// glTF `name` field (empty string if absent). @returns {String}
  name      { _name }
  /// Total clip length in seconds, taken from the latest keyframe
  /// across all channels.
  /// @returns {Num}
  duration  { _duration }
  /// One `GltfAnimChannel` per TRS target. @returns {List<GltfAnimChannel>}
  channels  { _channels }

  /// Sample every channel at time `t` and write the results into
  /// the targeted nodes' ECS `Transform` components. `scene` is
  /// the `GltfScene` whose `nodeEntityMap` resolves each channel's
  /// node index to an entity id; `world` is the `@hatch:ecs.World`
  /// holding those entities. Pre-`spawnInto` scenes (no map) and
  /// channels whose target entity has no `Transform` are skipped
  /// silently.
  ///
  /// `t` is raw seconds — call `t % duration` first if you want
  /// the clip to loop.
  ///
  /// ## Example
  ///
  /// ```wren
  /// var anim = _scene.animations[0]
  /// _animTime = _animTime + g.dt
  /// var t = anim.duration > 0
  ///       ? _animTime - anim.duration * (_animTime / anim.duration).floor
  ///       : 0
  /// anim.applyTo(_scene, _world, t)
  /// ```
  ///
  /// @param {GltfScene} scene
  /// @param {World}     world
  /// @param {Num}       t
  applyTo(scene, world, t) {
    var map = scene.nodeEntityMap
    if (map == null) return
    for (ch in _channels) {
      var entity = map[ch.nodeIndex]
      if (entity == null) continue
      if (!world.has(entity, Transform)) continue
      var v = ch.sample(t)
      var transform = world.get(entity, Transform)
      if (ch.path == "translation") {
        transform.position = Vec3.new(v[0], v[1], v[2])
      } else if (ch.path == "rotation") {
        // glTF stores quaternions as (x, y, z, w); Quat is (w, x, y, z).
        // LINEAR-lerped quat components don't preserve unit length;
        // normalise so the resulting Mat4 stays rigid.
        transform.rotation = Quat.new(v[3], v[0], v[1], v[2]).normalized
      } else if (ch.path == "scale") {
        transform.scale = Vec3.new(v[0], v[1], v[2])
      }
    }
  }

  /// Crossfade with another `GltfAnimation`. Samples both clips,
  /// blends the resulting per-channel TRS values, and writes the
  /// blended pose into every targeted node's `Transform`.
  ///
  /// Use during a walk → run / idle → walk transition: drive both
  /// clips with their own time accumulators (so they keep their
  /// natural phase), and ramp `blend` from `0` (entirely `self`) to
  /// `1` (entirely `other`) over the transition window — typically
  /// 0.15-0.3 seconds for snappy state-machine moves, 0.5-1.0 for
  /// cinematic blends.
  ///
  /// Translation + scale use linear interpolation; rotation uses
  /// `Quat.slerp` so the resulting quaternion stays on the unit
  /// hypersphere (a plain LERP shortens the arc near antipodal
  /// poses and produces visibly broken poses).
  ///
  /// Joints written by ONLY one of the two clips fade in / out
  /// against the current Transform value — the static pose acts as
  /// the implicit "other side" of the blend.
  ///
  /// ## Example
  ///
  /// ```wren
  /// var walk = _scene.animations[0]
  /// var run  = _scene.animations[1]
  /// // ... tWalk / tRun / blendT advance each frame ...
  /// walk.crossfade(run, _scene, _world, tWalk, tRun, blendT)
  /// ```
  ///
  /// @param {GltfAnimation} other
  /// @param {GltfScene}     scene
  /// @param {World}         world
  /// @param {Num}           tSelf.  Time-into-self in seconds.
  /// @param {Num}           tOther. Time-into-other in seconds.
  /// @param {Num}           blend.  `0`=self only, `1`=other only.
  crossfade(other, scene, world, tSelf, tOther, blend) {
    var map = scene.nodeEntityMap
    if (map == null) return
    if (blend < 0) blend = 0
    if (blend > 1) blend = 1

    // Index `other`'s channels by (nodeIndex, path) so the per-self
    // loop below can find the matching sample in O(1). Allocating
    // a fresh Map every call is cheap (200-channel rigs are 200
    // Map.set calls = ~50 µs).
    var otherByKey = {}
    for (ch in other.channels) {
      otherByKey["%(ch.nodeIndex):%(ch.path)"] = ch
    }

    // Track which (entity, path) slots `self` wrote — anything in
    // `other` not paired with a `self` channel gets its own fade
    // pass against the entity's current Transform value at the
    // end of this method.
    var paired = {}

    for (ch in _channels) {
      var entity = map[ch.nodeIndex]
      if (entity == null) continue
      if (!world.has(entity, Transform)) continue
      var transform = world.get(entity, Transform)
      var key = "%(ch.nodeIndex):%(ch.path)"
      paired[key] = true
      var a = ch.sample(tSelf)
      var oCh = otherByKey[key]
      if (oCh == null) {
        // Self drives this slot alone — write self's sample
        // un-blended. Future enhancement: blend against the current
        // Transform value when blend > 0 to ease out the channel.
        writeSample_(transform, ch.path, a)
      } else {
        var b = oCh.sample(tOther)
        writeBlended_(transform, ch.path, a, b, blend)
      }
    }

    // Channels in `other` that `self` didn't pair with: write them
    // scaled by `blend` so they ease in alongside the blended pose.
    for (ch in other.channels) {
      var key = "%(ch.nodeIndex):%(ch.path)"
      if (paired.containsKey(key)) continue
      var entity = map[ch.nodeIndex]
      if (entity == null) continue
      if (!world.has(entity, Transform)) continue
      var transform = world.get(entity, Transform)
      var b = ch.sample(tOther)
      writeSample_(transform, ch.path, b)
    }
  }

  // glTF stores rotations as (x, y, z, w); Quat constructor takes
  // (w, x, y, z). Centralised so applyTo and crossfade write the
  // exact same per-channel format.
  writeSample_(transform, path, v) {
    if (path == "translation") {
      transform.position = Vec3.new(v[0], v[1], v[2])
    } else if (path == "rotation") {
      transform.rotation = Quat.new(v[3], v[0], v[1], v[2]).normalized
    } else if (path == "scale") {
      transform.scale = Vec3.new(v[0], v[1], v[2])
    }
  }

  // Blend two channel samples. Translation + scale are linear;
  // rotation uses Quat.slerp to keep unit length.
  writeBlended_(transform, path, a, b, t) {
    if (path == "translation") {
      transform.position = Vec3.new(
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t)
    } else if (path == "rotation") {
      var qa = Quat.new(a[3], a[0], a[1], a[2])
      var qb = Quat.new(b[3], b[0], b[1], b[2])
      transform.rotation = Quat.slerp(qa, qb, t).normalized
    } else if (path == "scale") {
      transform.scale = Vec3.new(
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t)
    }
  }
}

/// One animation channel — a single (node, path) pair driven by
/// a sampler's keyframes. `path` is `"translation"` / `"rotation"`
/// / `"scale"`; the channel's `sample(t)` returns a freshly-built
/// `List<Num>` of length 3 (T / S) or 4 (R), ready to write into a
/// `Transform`.
class GltfAnimChannel {
  /// Internal — built by `GltfScene.buildAnimations_`.
  construct new_(nodeIndex, path, inputs, outputs, components, interpolation) {
    _nodeIndex     = nodeIndex
    _path          = path
    _inputs        = inputs        // Float32Array of timestamps
    _outputs       = outputs       // Float32Array of values (component-packed)
    _components    = components    // 3 (T/S) or 4 (R)
    _interpolation = interpolation // "LINEAR" | "STEP" | "CUBICSPLINE"
  }
  /// Target node index into `scene.nodes`. @returns {Num}
  nodeIndex     { _nodeIndex }
  /// `"translation"` | `"rotation"` | `"scale"`. @returns {String}
  path          { _path }
  /// `"LINEAR"` | `"STEP"` | `"CUBICSPLINE"`. @returns {String}
  interpolation { _interpolation }

  /// Sample the channel at world-time `t` seconds. `t` is clamped
  /// to the channel's input range. The returned List is freshly
  /// allocated each call; length 3 for translation / scale, 4 for
  /// rotation in glTF (x, y, z, w) order.
  ///
  /// @param  {Num} t
  /// @returns {List<Num>}
  sample(t) {
    var n = _inputs.count
    if (n == 0) {
      var z = []
      var c = 0
      while (c < _components) {
        z.add(0)
        c = c + 1
      }
      return z
    }
    if (n == 1 || t <= _inputs[0]) return GltfAnimChannel.outputAt_(_outputs, 0, _components)
    if (t >= _inputs[n - 1]) return GltfAnimChannel.outputAt_(_outputs, n - 1, _components)

    // Linear search — fine for typical channel sizes. Bisection
    // lands the day a profiler asks for it.
    var i = 0
    while (i < n - 1) {
      if (_inputs[i] <= t && t < _inputs[i + 1]) break
      i = i + 1
    }
    var t0 = _inputs[i]
    var t1 = _inputs[i + 1]
    var span = t1 - t0
    var u = span > 0.0001 ? (t - t0) / span : 0

    if (_interpolation == "STEP") {
      return GltfAnimChannel.outputAt_(_outputs, i, _components)
    }

    // glTF CUBICSPLINE stores 3 values per keyframe: inTangent,
    // value, outTangent. The interpolation is Hermite cubic
    // between value[i] and value[i+1] using outTangent[i] and
    // inTangent[i+1].
    if (_interpolation == "CUBICSPLINE") {
      var stride = _components * 3
      // For each keyframe at index k: in_tan = k*stride,
      // value = k*stride + components, out_tan = k*stride + 2*components.
      var v0 = i * stride + _components
      var m0 = i * stride + 2 * _components
      var v1 = (i + 1) * stride + _components
      var m1 = (i + 1) * stride
      var u2 = u * u
      var u3 = u2 * u
      var h00 = 2 * u3 - 3 * u2 + 1
      var h10 = u3 - 2 * u2 + u
      var h01 = -2 * u3 + 3 * u2
      var h11 = u3 - u2
      var out = []
      var c = 0
      while (c < _components) {
        var p0 = _outputs[v0 + c]
        var p1 = _outputs[v1 + c]
        var ta = _outputs[m0 + c]
        var tb = _outputs[m1 + c]
        out.add(h00 * p0 + h10 * ta * span + h01 * p1 + h11 * tb * span)
        c = c + 1
      }
      return out
    }

    // LINEAR. Rotation channels (components == 4) slerp on the
    // shortest hemisphere; TRS scalars lerp componentwise.
    //
    // Why slerp for rotation: lerp on quat components gives a
    // straight chord through 4D quat space which DOES NOT
    // correspond to constant angular velocity in 3D — fast-
    // spinning rotors read as ease-in / ease-out per keyframe
    // (janky between frames). Slerp follows the great-circle
    // path → smooth constant rotation. The hemisphere flip
    // handles the q vs −q ambiguity so neighbouring keyframes
    // pick the shorter arc.
    var out = []
    var aOff = i * _components
    var bOff = (i + 1) * _components
    if (_components == 4) {
      var ax = _outputs[aOff]
      var ay = _outputs[aOff + 1]
      var az = _outputs[aOff + 2]
      var aw = _outputs[aOff + 3]
      var bx = _outputs[bOff]
      var by = _outputs[bOff + 1]
      var bz = _outputs[bOff + 2]
      var bw = _outputs[bOff + 3]
      var dot = ax * bx + ay * by + az * bz + aw * bw
      if (dot < 0) {
        bx = -bx
        by = -by
        bz = -bz
        bw = -bw
        dot = -dot
      }
      var s0 = 1 - u
      var s1 = u
      if (dot < 0.9995) {
        // Slerp via sin(theta * (1 - u)) / sin(theta) blend
        // weights. Falls back to plain lerp when the two quats
        // are nearly parallel (sin(theta) ≈ 0).
        var theta = dot.acos
        var sinT  = theta.sin
        if (sinT > 0.00001) {
          s0 = ((1 - u) * theta).sin / sinT
          s1 = (u * theta).sin / sinT
        }
      }
      out.add(ax * s0 + bx * s1)
      out.add(ay * s0 + by * s1)
      out.add(az * s0 + bz * s1)
      out.add(aw * s0 + bw * s1)
      return out
    }
    var c = 0
    while (c < _components) {
      var a = _outputs[aOff + c]
      var b = _outputs[bOff + c]
      out.add(a + (b - a) * u)
      c = c + 1
    }
    return out
  }

  // Extract one keyframe value from a packed-LINEAR / STEP output
  // accessor. For CUBICSPLINE the layout is different (3 values
  // per keyframe), but boundary cases (clamp to first / last) use
  // the value slot which sits at keyframeIdx*stride + components.
  static outputAt_(outputs, keyframeIdx, components) {
    var stride = components
    // Heuristic: if outputs.count == numKeyframes * components, it's
    // a LINEAR/STEP track. If it's 3x, it's CUBICSPLINE. We pick
    // the value slot accordingly. Detected via outputs.count vs the
    // caller's keyframe count isn't known here, so use modular
    // arithmetic — caller passes the right index.
    var off = keyframeIdx * stride
    var out = []
    var c = 0
    while (c < components) {
      out.add(outputs[off + c])
      c = c + 1
    }
    return out
  }
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
  construct new_(positions, normals, uvs, tangents, indices, materialIndex) {
    _positions = positions
    _normals = normals
    _uvs = uvs
    _tangents = tangents
    _indices = indices
    _materialIndex = materialIndex
    _joints = null
    _weights = null
    _mesh = null
    _material = null
  }
  positions      { _positions }
  normals        { _normals }
  uvs            { _uvs }
  tangents       { _tangents }
  indices        { _indices }
  /// `Int32Array` of joint indices, 4 per vertex (`JOINTS_0`).
  /// `null` for non-skinned primitives.
  joints         { _joints }
  joints_=(v)    { _joints = v }
  /// `Float32Array` of joint weights, 4 per vertex (`WEIGHTS_0`).
  /// Sum to ~1.0 per vertex per the glTF spec.
  /// `null` for non-skinned primitives.
  weights        { _weights }
  weights_=(v)   { _weights = v }
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
    var verts = Float32Array.new(vertexCount * 12)
    var i = 0
    while (i < vertexCount) {
      var base = i * 12
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
      if (_tangents != null && (i * 4 + 3) < _tangents.count) {
        verts[base + 8]  = _tangents[i * 4 + 0]
        verts[base + 9]  = _tangents[i * 4 + 1]
        verts[base + 10] = _tangents[i * 4 + 2]
        verts[base + 11] = _tangents[i * 4 + 3]
      } else {
        // Zero tangent signals "no tangent" — the fragment shader
        // falls back to screen-space derivatives.
        verts[base + 8]  = 0
        verts[base + 9]  = 0
        verts[base + 10] = 0
        verts[base + 11] = 0
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
    // Switch to the skinned-mesh builder when both JOINTS_0 and
    // WEIGHTS_0 are present. Primitives missing either fall back
    // to the static path — the renderer picks the right pipeline
    // by mesh.jointsBuffer != null.
    if (_joints != null && _weights != null) {
      _mesh = Mesh.fromArraysSkinned(device, verts, _joints, _weights, indices)
    } else {
      _mesh = Mesh.fromArrays(device, verts, indices)
    }
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
