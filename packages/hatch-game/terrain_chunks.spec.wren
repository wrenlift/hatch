// @hatch:game/terrain_chunks — TerrainChunk + TerrainStreamer.

import "./terrain_chunks" for TerrainChunk, TerrainStreamer
import "@hatch:test"      for Test
import "@hatch:assert"    for Expect

// Terrain.meshFromHeightmap calls device.createBuffer; mock the
// minimal surface it touches so we can build chunks without
// requesting a real GPU device.
class MockBuf {
  construct new() { _destroyed = false }
  writeFloats(off, data) {}
  writeUints(off, data) {}
  destroy { _destroyed = true }
  isDestroyed { _destroyed }
}

class MockDev {
  construct new() {
    _buffers = []
  }
  createBuffer(desc) {
    var b = MockBuf.new()
    _buffers.add(b)
    return b
  }
  buffers { _buffers }
}

var flat = Fn.new {|x, z| 0 }
var slope = Fn.new {|x, z| x * 0.1 + z * 0.05 }

Test.describe("TerrainChunk") {
  Test.it("samples the heightmap at every cell in row-major order") {
    var dev = MockDev.new()
    var chunk = TerrainChunk.new(dev, 2, 3, 8.0, 5, slope)
    Expect.that(chunk.ix).toBe(2)
    Expect.that(chunk.iz).toBe(3)
    Expect.that(chunk.size).toBe(8.0)
    Expect.that(chunk.res).toBe(5)
    Expect.that(chunk.heights.count).toBe(25)
    // Corner at (ix * size, iz * size) = (16, 24). Float32
    // round-trip drops precision off doubles, so compare within
    // an epsilon.
    var expected = slope.call(16, 24)
    var delta = chunk.heights[0] - expected
    if (delta < 0) delta = -delta
    Expect.that(delta < 0.0001).toBe(true)
    // World-space centre is the chunk centre.
    Expect.that(chunk.centreX).toBe(20)
    Expect.that(chunk.centreZ).toBe(28)
  }

  Test.it("aborts on res < 2") {
    var dev = MockDev.new()
    var e = Fiber.new { TerrainChunk.new(dev, 0, 0, 8, 1, flat) }.try()
    Expect.that(e).toContain("res must be >= 2")
  }

  Test.it("destroy is idempotent + flips isAlive") {
    var dev = MockDev.new()
    var chunk = TerrainChunk.new(dev, 0, 0, 8, 3, flat)
    Expect.that(chunk.isAlive).toBe(true)
    chunk.destroy
    Expect.that(chunk.isAlive).toBe(false)
    // Second destroy is a no-op (doesn't abort).
    chunk.destroy
    Expect.that(chunk.isAlive).toBe(false)
  }
}

Test.describe("TerrainStreamer.update") {
  Test.it("aborts without heightSampler") {
    var dev = MockDev.new()
    var e = Fiber.new {
      TerrainStreamer.new(dev, {"chunkSize": 32})
    }.try()
    Expect.that(e).toContain("heightSampler")
  }

  Test.it("loads a (2*radius+1)^2 window of chunks around the focus") {
    var dev = MockDev.new()
    var s = TerrainStreamer.new(dev, {
      "chunkSize":     32,
      "resolution":    3,
      "radius":        1,
      "heightSampler": flat
    })
    s.update(0, 0)
    // 3 × 3 grid centred at (0,0) → 9 chunks.
    Expect.that(s.count).toBe(9)
  }

  Test.it("unloads chunks the focus has left and loads new ones") {
    var dev = MockDev.new()
    var s = TerrainStreamer.new(dev, {
      "chunkSize":     32,
      "resolution":    3,
      "radius":        1,
      "heightSampler": flat
    })
    s.update(0, 0)         // 9 chunks at cells (-1..1, -1..1)
    Expect.that(s.count).toBe(9)
    s.update(160, 0)        // focus cell (5, 0) — completely disjoint window
    // Disjoint window → 9 new chunks, all 9 originals unloaded.
    Expect.that(s.count).toBe(9)
    // No chunk overlap with the original (-1..1, -1..1).
    for (c in s.activeChunks) {
      Expect.that(c.ix >= 4 && c.ix <= 6).toBe(true)
    }
  }

  Test.it("maxLoadsPerUpdate caps spawn count per call and loads closest first") {
    var dev = MockDev.new()
    var s = TerrainStreamer.new(dev, {
      "chunkSize":         32,
      "resolution":        3,
      "radius":            2,
      "heightSampler":     flat,
      "maxLoadsPerUpdate": 1
    })
    s.update(0, 0)
    // Budget of 1 per call → only one chunk built on the first
    // update.
    Expect.that(s.count).toBe(1)
    // Closest cell (centre) is (0, 0).
    var c = s.activeChunks.toList[0]
    Expect.that(c.ix).toBe(0)
    Expect.that(c.iz).toBe(0)
    // Subsequent updates fill in the next-closest neighbours.
    s.update(0, 0)
    Expect.that(s.count).toBe(2)
  }

  Test.it("clear() destroys every live chunk") {
    var dev = MockDev.new()
    var s = TerrainStreamer.new(dev, {
      "chunkSize":     32,
      "resolution":    3,
      "radius":        1,
      "heightSampler": flat
    })
    s.update(0, 0)
    Expect.that(s.count).toBe(9)
    s.clear()
    Expect.that(s.count).toBe(0)
  }
}

Test.run()
