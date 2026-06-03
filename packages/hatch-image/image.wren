// `@hatch:image`. Encode and decode RGBA8 image buffers.
//
// ```wren
// import "@hatch:image"  for Image
// import "@hatch:assets" for Assets
// import "@hatch:gpu"    for Gpu
//
// var assets = Assets.open("assets")
// var img    = Image.decode(assets.bytes("hero.png"))
// System.print("loaded %(img.width)x%(img.height)")
//
// // Hand straight to @hatch:gpu. No glue code needed; it
// // duck-types on .width / .height / .pixels.
// var device = Gpu.requestDevice()
// var tex    = device.uploadImage(img)
//
// // Round-trip: encode a procedurally-built buffer.
// var bytes  = Image.encode("png", img.width, img.height, img.pixels)
// ```
//
// PNG, JPEG, BMP, and WebP decode are supported; encode covers
// PNG / JPEG / BMP. Pixels are always row-major RGBA8. Alpha is
// preserved on decode and required on encode.

#!native = "wlift_image"
foreign class ImageCore {
  #!symbol = "wlift_image_decode"
  foreign static decode(bytes)

  #!symbol = "wlift_image_encode"
  foreign static encode(format, width, height, pixels)

  // Async decode surface. `decodeBegin` returns a numeric job id;
  // pair with `pollDecode` (0 = pending, 1 = ready, 2 = failed),
  // then `takeDecode` (drains a Ready job into a Map) or
  // `takeDecodeError` (drains a Failed job into a String).
  // `cancelDecode` releases a job slot without polling it; useful
  // when a loader aborts mid-flight. `inflightDecodes` is a
  // diagnostic — count of live entries in the job registry.
  #!symbol = "wlift_image_decode_begin"
  foreign static decodeBegin(bytes)

  #!symbol = "wlift_image_poll"
  foreign static pollDecode(jobId)

  #!symbol = "wlift_image_take"
  foreign static takeDecode(jobId)

  #!symbol = "wlift_image_take_error"
  foreign static takeDecodeError(jobId)

  #!symbol = "wlift_image_cancel"
  foreign static cancelDecode(jobId)

  #!symbol = "wlift_image_inflight"
  foreign static inflightDecodes()
}

/// Handle to an in-flight PNG/JPEG/BMP/WebP decode running on a
/// background worker thread. Poll `isReady` (or `isFailed`) every
/// frame; once `isReady`, read `.result` to drain the worker's
/// pixel buffer into a fresh `Image` on the VM thread.
///
/// ## Lifecycle
///
/// A handle MUST be drained (either `result` or `errorMessage`) OR
/// explicitly `cancel`led — otherwise its pixel buffer leaks in the
/// plugin's job registry until process exit. `AssetLoader.queueDecode`
/// drives this for you; bare callers should pair every `decodeBegin`
/// with one of the three.
///
/// ## Example — polling from a game-loop update
///
/// ```wren
/// import "@hatch:image" for Image
///
/// // Kick off the decode (returns immediately, no blocking).
/// var handle = Image.decodeBegin(db.bytes("hero.png"))
///
/// // Per-frame: render the loading screen, poll for completion.
/// update(g) {
///   if (handle.isReady) {
///     _hero = handle.result
///   } else if (handle.isFailed) {
///     System.print("hero decode failed: %(handle.errorMessage)")
///   }
/// }
/// ```
class ImageDecodeHandle {
  construct new_(jobId) {
    _jobId   = jobId
    _result  = null   // cached Image once result has been drained
    _error   = null   // cached String once errorMessage has been drained
    _drained = false
  }

  /// True while the worker hasn't finished. Calling `result` in
  /// this state aborts.
  isPending {
    if (_drained) return false
    return ImageCore.pollDecode(_jobId) == 0
  }

  /// True once the decoded pixels are available. `result` is safe
  /// to call when this returns true.
  isReady {
    if (_drained && _result != null) return true
    return ImageCore.pollDecode(_jobId) == 1
  }

  /// True once the worker reported a decode failure. `errorMessage`
  /// is safe to call when this returns true.
  isFailed {
    if (_drained && _error != null) return true
    return ImageCore.pollDecode(_jobId) == 2
  }

  /// `"pending"` | `"ready"` | `"failed"` | `"consumed"` — handy
  /// for logging + HUD overlays that surface decode progress.
  status {
    if (_drained) return _result != null ? "consumed" : "consumed_error"
    var code = ImageCore.pollDecode(_jobId)
    if (code == 0) return "pending"
    if (code == 1) return "ready"
    return "failed"
  }

  /// Drain the worker's pixel buffer into a fresh `Image` on the
  /// VM thread. First call performs the drain; subsequent calls
  /// return the cached `Image`. Aborts if the job is still pending
  /// or has failed.
  result {
    if (_result != null) return _result
    if (_drained) Fiber.abort("ImageDecodeHandle.result: handle already drained as error.")
    var rec = ImageCore.takeDecode(_jobId)
    _result  = Image.new_(rec["width"], rec["height"], rec["pixels"])
    _drained = true
    return _result
  }

  /// Drain the worker's failure message. First call performs the
  /// drain; subsequent calls return the cached String. Aborts if
  /// the job is still pending or completed successfully.
  errorMessage {
    if (_error != null) return _error
    if (_drained) Fiber.abort("ImageDecodeHandle.errorMessage: handle already drained as result.")
    _error   = ImageCore.takeDecodeError(_jobId)
    _drained = true
    return _error
  }

  /// Release the job slot without polling it. After cancel, every
  /// subsequent isReady / isFailed call returns false and result /
  /// errorMessage abort. Safe to call from any state — pending
  /// workers see the slot disappear and silently discard their
  /// result.
  cancel() {
    if (!_drained) {
      ImageCore.cancelDecode(_jobId)
      _drained = true
    }
  }

  toString { "ImageDecodeHandle(#%(_jobId), %(status))" }
}

class Image {
  /// Decode bytes (List<Num> or ByteArray) into an Image. Format
  /// is sniffed from the magic bytes; alpha is always present in
  /// the output.
  static decode(bytes) {
    var rec = ImageCore.decode(bytes)
    return Image.new_(rec["width"], rec["height"], rec["pixels"])
  }

  /// Begin a non-blocking decode on a worker thread. Returns an
  /// `ImageDecodeHandle` the caller polls each frame. The
  /// synchronous `Image.decode` is still available for callers
  /// that don't want the polling boilerplate; prefer `decodeBegin`
  /// in game-loop / asset-load paths where a multi-second PNG
  /// decode would otherwise freeze the window.
  ///
  /// On wasm32 the decode runs inline on the calling fiber — the
  /// API contract is preserved but there's no real backgrounding.
  /// The browser-bridge fiber-yield path is the right async story
  /// on web and is tracked separately.
  static decodeBegin(bytes) {
    var id = ImageCore.decodeBegin(bytes)
    return ImageDecodeHandle.new_(id)
  }

  /// Diagnostic — number of `decodeBegin` jobs still tracked by
  /// the plugin (Pending + Ready not yet drained + Failed not yet
  /// drained). Stable across native + wasm. Returns 0 when no
  /// async decode has been issued.
  static inflightDecodes { ImageCore.inflightDecodes() }

  /// Encode RGBA8 pixels to the chosen file format. `format` is
  /// "png", "jpeg" / "jpg", or "bmp". Returns a ByteArray ready
  /// for FS.writeBytes / network upload / archive packaging.
  static encode(format, width, height, pixels) {
    return ImageCore.encode(format, width, height, pixels)
  }
  static encodePng(width, height, pixels)  { encode("png",  width, height, pixels) }
  static encodeJpeg(width, height, pixels) { encode("jpeg", width, height, pixels) }
  static encodeBmp(width, height, pixels)  { encode("bmp",  width, height, pixels) }

  // Hand-build an Image from arbitrary RGBA8 bytes. Useful when
  // generating textures procedurally (an SDF, a noise tile, or
  // composing an atlas). Same constructor `Image.decode` and
  // `Image.encode` use internally; keeps the surface small.
  //
  // `pixels` accepts a `List<Num>` (each cast to u8) or a
  // `ByteArray`; either way it is stored internally as a
  // `ByteArray`. That uniformity matters for downstream consumers,
  // most importantly `@hatch:gpu`'s `writeTexture` path on wasm32,
  // where the JS bridge reads slot bytes via `wrenGetSlotBytes` and
  // only resolves a real pointer when the slot holds a String or
  // TypedArray. Passing a raw List works on the native runtime
  // (which has a List-to-bytes coercion path) but the wasm bridge
  // sees a null pointer and the texture upload aborts. Coercing
  // here means callers do not have to care about the target.
  construct new_(width, height, pixels) {
    _w = width
    _h = height
    _p = (pixels is List) ? ByteArray.fromList(pixels) : pixels
  }
  static new(width, height, pixels) { Image.new_(width, height, pixels) }

  width  { _w }
  height { _h }
  pixels { _p }

  toString { "Image(%(_w)x%(_h), %(_p.count) bytes)" }
}
