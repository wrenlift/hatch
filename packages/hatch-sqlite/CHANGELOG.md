# Changelog

## 0.1.11 — 2026-06-04

Plugin dylib rebuilt against wren_lift `7566533` (was `e52ba41`).
Picks up the cross-plugin GC root fixes that landed after
`e52ba41` — `c7eb482` (root map + key locals across allocator
calls), `9aeabba` (close GC root miss in foreign methods +
entry-block params), and `129be0f` (image-plugin root tracking
template that applies here too).

Fixes a `Database: use after close` crash observed in
production: under wren_lift `7566533` the `System.gc()` call
inside long-running consumers (e.g. `Catalog.refresh()` on the
hatch site) could sweep the Database foreign object as
unreachable because the old plugin entry points didn't keep
the handle alive across internal allocator calls. After this
rebuild the handle stays rooted for the duration of every
foreign method.

