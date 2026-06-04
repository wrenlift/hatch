# Changelog

## 0.1.6 -- 2026-06-04

Maintenance bump for the publish wave (2026-06-04). Pairs
with the `@hatch:buffers` 0.1.3 release that lands
`ByteArray.parseF64` + `toUtf8String` + `utf8Slice` — wiring
those into `JSON.parse`'s hot path is deferred until the
intermittent JIT method-OSR crash on static-return paths
is resolved.
