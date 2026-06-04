# Changelog

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
