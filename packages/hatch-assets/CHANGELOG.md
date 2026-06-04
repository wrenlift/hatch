# Changelog

## 0.2.6 -- 2026-06-04

- `AssetLoader.queueDecode` integrates with `@hatch:image`'s
  new `decodeBegin` / `ImageDecodeHandle` worker-thread
  pipeline so per-FFI image decodes happen off the main
  fiber.
- Pairs with the `StateChart` + HUD progress-bar pattern in
  the skeletal-animation-demo and procedural-world examples.
- Picks up runtime fixes from `wren_lift` (AOT GC stack-map
  closure for foreign methods, Fiber.try() stale-slot guard).
