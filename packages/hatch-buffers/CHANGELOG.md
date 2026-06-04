# Changelog

## 0.1.3 -- 2026-06-04

- `ByteArray.toUtf8String` + `ByteArray.utf8Slice(off, len)`:
  native primitives that decode a utf-8 span without
  intermediate `List<Num>` round-trips. Cuts the bottleneck
  in `JSON.parse` and `Toml.parse` paths.
- `ByteArray.parseF64(off, len)`: fused number-parse
  primitive — single pass, no intermediate substring.
- `Fs.readBytes` now returns a `ByteArray` (previously
  `List<Num>`) so file reads pipe straight into the new
  primitives without conversion.
- Native bulk-decoder methods on `ByteArray` cover the common
  fixed-width little-endian formats.
