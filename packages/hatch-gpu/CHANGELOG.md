# Changelog

## 0.3.15 — 2026-06-04

Plugin dylib rebuilt against wren_lift `7566533` (was `e52ba41`
/ older). Picks up the cross-plugin GC root tracking added since
the prior pin — specifically `c7eb482` (plugins: root map +
key locals across allocator calls), `9aeabba` (close GC root
miss in foreign methods + entry-block params), and the related
JIT-roots-store release work. Hosts running newer wren_lift
could otherwise sweep the plugin's foreign objects as
unreachable across allocator calls in the foreign method body.

## 0.3.14 -- 2026-06-04

- Compute pipeline + compute pass + fast typed-array readback
  for GPU-side buffers.
- `RenderPass` command decoder gains `DrawIndexedIndirect` so
  Wren-driven indirect draws round-trip through the wgpu
  backend.
- Plugin-side: GPU blend descriptors + comparison sampler
  land for the broader rendering matrix the procedural-world
  and animation-showcase examples exercise.
- Picks up the `wren_lift` JIT/AOT GC stack-map fixes that
  closed the foreign-method root-miss class.
