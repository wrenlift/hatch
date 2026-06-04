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

Maintenance release on top of the 0.2.0 OGG-decode + 4-bus
mixer rework. No new surface; picks up plugin ABI fixes
(opaque-VM C shim migration) and the latest GC stack-map
closure for foreign methods.
