# Changelog

## 0.2.15 — 2026-06-04

Plugin dylib rebuilt against wren_lift `7ff1310d5037bbc3af32dcc0bdf74f387590fac1`. The prior
`7566533` rebuild lost its publish race because the Linux
build matrix in publish-plugin.yml only apt-got libasound2-dev,
so wlift_window's transitive libudev-sys build script aborted
on both x86_64 and arm64. Today's wren_lift Cross.toml + hatch
publish-plugin.yml updates install the full winit linux dep
stack (libudev + libxkbcommon + libwayland + libx11 + libxcb1
+ libxrandr + libxinerama + libxcursor + libxi) in both the
native-runner and cross-rs container paths, so this rebuild
produces a complete linux-x86_64 + linux-arm64 dylib pair.

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
