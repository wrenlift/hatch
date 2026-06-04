# Changelog

## 0.2.1 -- 2026-06-04

- Worley (cellular) noise + ridged-multi fBm variants.
- 3D bulk fill entry point + additional 2D bulk fillers so
  procedural-world heightmap + texture generation runs
  through native loops instead of per-cell FFI hops.
- Plugin: rolls in the broader plugin-ABI migration (opaque-
  VM C shim) shipped with the 2026-06-04 wave.
