Image encode and decode. PNG, JPEG, BMP, and WebP in; PNG, JPEG, and BMP out. Pixels are always row-major RGBA8 — alpha is preserved on decode and required on encode. Backed by the Rust `image` crate. The `Image` value duck-types on `.width` / `.height` / `.pixels`, so `@hatch:gpu`'s `Device.uploadImage(img)` takes it directly with no glue code.

## Overview

Three entry points: `Image.decode(bytes)` reads a buffer and sniffs the format from the magic bytes; `Image.encode(format, w, h, pixels)` (with `encodePng` / `encodeJpeg` / `encodeBmp` shortcuts) writes back out; `Image.new(w, h, pixels)` hand-builds an image from procedural RGBA8 bytes.

```wren
import "@hatch:image"  for Image
import "@hatch:assets" for Assets
import "@hatch:gpu"    for Gpu

var assets = Assets.open("assets")
var img    = Image.decode(assets.bytes("hero.png"))
System.print("loaded %(img.width)x%(img.height)")

var device = Gpu.requestDevice()
var tex    = device.uploadImage(img)

var bytes = Image.encodePng(img.width, img.height, img.pixels)
```

`pixels` accepts either a `List<Num>` (each cast to u8) or a `ByteArray` and stores them internally as `ByteArray`. That uniformity matters for the GPU upload path on `#!wasm`, where the JS bridge needs a real bytes pointer to read from.

## Round-trip and procedural images

Build a texture in code, hand it to the GPU, optionally write it to disk:

```wren
var pixels = ByteArray.new(64 * 64 * 4)
// ...fill in an SDF, gradient, noise tile, etc.
var img = Image.new(64, 64, pixels)
var tex = device.uploadImage(img)
Fs.writeBytes("out.png", Image.encodePng(64, 64, pixels))
```

> **Note — alpha is mandatory**
> RGBA8 means four bytes per pixel. If your source data is RGB, expand it to RGBA (alpha 255 for opaque) before calling `encode` — passing a 3-channel buffer aborts with a length-mismatch error.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Native only — `#!wasm` builds reach for browser-side decoders through `@hatch:web`. Pair with `@hatch:gpu` for texture upload, with `@hatch:assets` for hot-reloadable image content.
