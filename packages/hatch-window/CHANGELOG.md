# Changelog

## 0.2.14 — 2026-06-04

Plugin dylib rebuilt against wren_lift `7566533` (was `e52ba41`
/ older). Picks up the cross-plugin GC root tracking added since
the prior pin — specifically `c7eb482` (plugins: root map +
key locals across allocator calls), `9aeabba` (close GC root
miss in foreign methods + entry-block params), and the related
JIT-roots-store release work. Hosts running newer wren_lift
could otherwise sweep the plugin's foreign objects as
unreachable across allocator calls in the foreign method body.

## 0.2.13 -- 2026-06-04

- Stores the physical inner_size on the Window record so
  retina swap-chain setup can compute the actual surface
  resolution without re-querying winit each frame.
- New `Window.setVisible` (paired with the hidden-then-show
  lifecycle in `@hatch:game`) lets games open the window
  hidden, finish GPU init, paint a clean first frame, then
  flip visibility — fixes the white-flash + retina
  swap-chain mismatch on cold boot.
- Plugin: gilrs gamepad surface, cursor lock/hide helpers,
  mouse-wheel delta channel.
