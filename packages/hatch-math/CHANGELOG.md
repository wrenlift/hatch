# Changelog

## 0.1.7 -- 2026-06-04

- Non-allocating rotation primitives + `positionInto` /
  `rotationInto` helpers so per-frame physics + animation
  reads stop allocating temp vectors. Drops procedural-world
  per-frame allocations into the noise floor.
- Sibling release of `@hatch:physics` 0.1.8, which consumes
  the new non-allocating surface.
