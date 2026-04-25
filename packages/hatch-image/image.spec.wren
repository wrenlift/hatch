// @hatch:image acceptance tests. Round-trips a synthesised image
// through encode + decode for every supported format.

import "./image"        for Image
import "@hatch:test"    for Test
import "@hatch:assert"  for Expect

// Build a 4x2 RGBA gradient procedurally — wlift_image accepts
// either a List<Num> or a ByteArray, so a plain List works fine.
var width  = 4
var height = 2
var pixels = []
var y = 0
while (y < height) {
  var x = 0
  while (x < width) {
    var r = (x * 64) % 256
    var g = (y * 100) % 256
    pixels.add(r)
    pixels.add(g)
    pixels.add(0)
    pixels.add(255)
    x = x + 1
  }
  y = y + 1
}

Test.describe("Image round-trip") {
  Test.it("encodes + decodes PNG without losing pixels") {
    var bytes = Image.encodePng(width, height, pixels)
    Expect.that(bytes.count > 8).toBe(true)
    var img = Image.decode(bytes)
    Expect.that(img.width).toBe(width)
    Expect.that(img.height).toBe(height)
    Expect.that(img.pixels[0]).toBe(0)
    Expect.that(img.pixels[1]).toBe(0)
    Expect.that(img.pixels[2]).toBe(0)
    Expect.that(img.pixels[3]).toBe(255)
  }

  Test.it("encodes BMP and decodes back to the same dimensions") {
    var bytes = Image.encodeBmp(width, height, pixels)
    var img = Image.decode(bytes)
    Expect.that(img.width).toBe(width)
    Expect.that(img.height).toBe(height)
  }

  Test.it("rejects pixel buffers of the wrong length") {
    var e = Fiber.new {
      Image.encodePng(width, height, [0, 0, 0])
    }.try()
    Expect.that(e).toContain("expected")
  }

  Test.it("rejects unknown formats") {
    var e = Fiber.new {
      Image.encode("tiff", width, height, pixels)
    }.try()
    Expect.that(e).toContain("unknown format")
  }
}

Test.describe("Image construction") {
  Test.it("Image.new(w, h, pixels) wraps a hand-built buffer") {
    var img = Image.new(2, 1, [255, 0, 0, 255, 0, 255, 0, 255])
    Expect.that(img.width).toBe(2)
    Expect.that(img.height).toBe(1)
    Expect.that(img.pixels.count).toBe(8)
  }
}

Test.run()
