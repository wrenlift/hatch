# Changelog

## 0.1.9 — 2026-06-04

Plugin dylib rebuilt against wren_lift `7566533` (was `e52ba41`
/ older). Picks up the cross-plugin GC root tracking added since
the prior pin — specifically `c7eb482` (plugins: root map +
key locals across allocator calls), `9aeabba` (close GC root
miss in foreign methods + entry-block params), and the related
JIT-roots-store release work. Hosts running newer wren_lift
could otherwise sweep the plugin's foreign objects as
unreachable across allocator calls in the foreign method body.

## 0.1.8 -- 2026-06-04

- Worker-thread async decode pipeline: `Image.decodeBegin`
  returns an `ImageDecodeHandle` that `AssetLoader.queueDecode`
  polls; per-job decode runs on a `std::thread` via the new
  `JobRegistry` (six entry points wired up).
- Plugin: GC roots map + pixel array held across allocator
  calls inside the decode path, closing the foreign-method
  root-miss class on the image side.
