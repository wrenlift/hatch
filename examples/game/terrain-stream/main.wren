// terrain-stream — drive a TerrainStreamer across a noise-driven
// world and log the per-update chunk diff. The streamer needs a
// `device.createBuffer` shape but renders nothing here; we mock
// the device so the example doesn't pull in a window.
//
// A real game loop would replace the mock with `g.device` and
// call `streamer.update(camera.x, camera.z)` once per frame; the
// chunks expose `.mesh` for the renderer.

import "@hatch:game"  for TerrainStreamer

class MockBuf {
  construct new() {}
  writeFloats(off, data) {}
  writeUints(off, data)  {}
  destroy {}
}

class MockDev {
  construct new() {}
  createBuffer(desc) { MockBuf.new() }
}

var dev = MockDev.new()
var sampler = Fn.new {|x, z| (x + z) * 0.1 }  // a synthetic ramp

var streamer = TerrainStreamer.new(dev, {
  "chunkSize":     32,
  "resolution":    9,
  "radius":        1,
  "heightSampler": sampler
})

System.print("Streamer @ radius=1 → 3×3 window of chunks.\n")
streamer.update(0, 0)
System.print("focus=(0,0)  loaded chunks: %(streamer.count)")
for (c in streamer.activeChunks) System.write("  (%(c.ix),%(c.iz))")
System.print("")

streamer.update(64, 0)
System.print("\nfocus=(64,0) — drifted one cell-width along +x")
System.print("loaded chunks: %(streamer.count)")
for (c in streamer.activeChunks) System.write("  (%(c.ix),%(c.iz))")
System.print("")

streamer.update(0, 0)
System.print("\nfocus=(0,0)   — back to origin")
System.print("loaded chunks: %(streamer.count)")
for (c in streamer.activeChunks) System.write("  (%(c.ix),%(c.iz))")
System.print("")
