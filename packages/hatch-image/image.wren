// @hatch:image — encode + decode RGBA8 image buffers.
//
//   import "@hatch:image"  for Image
//   import "@hatch:assets" for Assets
//   import "@hatch:gpu"    for Gpu
//
//   var assets = Assets.open("assets")
//   var img    = Image.decode(assets.bytes("hero.png"))
//   System.print("loaded %(img.width)x%(img.height)")
//
//   // Hand straight to @hatch:gpu — no glue code needed; it
//   // duck-types on .width / .height / .pixels.
//   var device = Gpu.requestDevice()
//   var tex    = device.uploadImage(img)
//
//   // Round-trip: encode a procedurally-built buffer.
//   var bytes  = Image.encode("png", img.width, img.height, img.pixels)
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
  // Decode bytes (List<Num> or ByteArray) into an Image. Format
  // is sniffed from the magic bytes; alpha is always present in
  // the output.
  static decode(bytes) {
    var rec = ImageCore.decode(bytes)
    return Image.new_(rec["width"], rec["height"], rec["pixels"])
  }

  // Encode RGBA8 pixels to the chosen file format. `format` is
  // "png", "jpeg" / "jpg", or "bmp". Returns a ByteArray ready
  // for FS.writeBytes / network upload / archive packaging.
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
  construct new_(width, height, pixels) {
    _w = width
    _h = height
    _p = pixels
  }
  static new(width, height, pixels) { Image.new_(width, height, pixels) }

  width  { _w }
  height { _h }
  pixels { _p }

  toString { "Image(%(_w)x%(_h), %(_p.count) bytes)" }
}
