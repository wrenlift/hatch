// `@hatch:image` — encode + decode RGBA8 image buffers.
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
// // Hand straight to @hatch:gpu — no glue code needed; it
// // duck-types on .width / .height / .pixels.
// var device = Gpu.requestDevice()
// var tex    = device.uploadImage(img)
//
// // Round-trip: encode a procedurally-built buffer.
// var bytes  = Image.encode("png", img.width, img.height, img.pixels)
// ```
//
// PNG, JPEG, BMP, and WebP decode are supported; encode covers
// PNG / JPEG / BMP. Pixels are always row-major RGBA8 — alpha is
// preserved on decode and required on encode.

#!native = "wlift_image"
foreign class ImageCore {
  #!symbol = "wlift_image_decode"
  foreign static decode(bytes)

  #!symbol = "wlift_image_encode"
  foreign static encode(format, width, height, pixels)
}

class Image {
  /// Decode bytes (List<Num> or ByteArray) into an Image. Format
  /// is sniffed from the magic bytes; alpha is always present in
  /// the output.
  static decode(bytes) {
    var rec = ImageCore.decode(bytes)
    return Image.new_(rec["width"], rec["height"], rec["pixels"])
  }

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
  // generating textures procedurally (e.g. an SDF, a noise tile,
  // or composing an atlas). Same constructor `Image.decode` /
  // `Image.encode` use internally — keeps the surface small.
  //
  // `pixels` accepts a `List<Num>` (each cast to u8) or a
  // `ByteArray`; either way it's stored internally as a
  // `ByteArray`. That uniformity matters for downstream consumers
  // — most importantly `@hatch:gpu`'s `writeTexture` path on
  // wasm32, where the JS bridge reads slot bytes via
  // `wrenGetSlotBytes` and only resolves a real pointer when the
  // slot holds a String / TypedArray. Passing a raw List works
  // on the native runtime (it has a List→bytes coercion path)
  // but the wasm bridge sees a null pointer and the texture
  // upload aborts. Coercing here means callers don't have to
  // care about the target.
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
