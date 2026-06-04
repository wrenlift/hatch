# Changelog

## 0.2.2 — 2026-06-04

Plugin dylib rebuilt against wren_lift `7566533` (was `e52ba41`
/ older). Picks up the cross-plugin GC root tracking added since
the prior pin — specifically `c7eb482` (plugins: root map +
key locals across allocator calls), `9aeabba` (close GC root
miss in foreign methods + entry-block params), and the related
JIT-roots-store release work. Hosts running newer wren_lift
could otherwise sweep the plugin's foreign objects as
unreachable across allocator calls in the foreign method body.

## 0.2.1 -- 2026-06-04

- Worley (cellular) noise + ridged-multi fBm variants.
- 3D bulk fill entry point + additional 2D bulk fillers so
  procedural-world heightmap + texture generation runs
  through native loops instead of per-cell FFI hops.
- Plugin: rolls in the broader plugin-ABI migration (opaque-
  VM C shim) shipped with the 2026-06-04 wave.
