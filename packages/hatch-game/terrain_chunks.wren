// @hatch:game/terrain_chunks — streaming chunk-grid terrain for
// large open worlds.
//
// `TerrainChunk` represents one tile of a tile-grid terrain: a
// world-space bounding box, a heightmap slice, and the GPU Mesh
// generated from it. `TerrainStreamer` orchestrates the grid:
// keeps a fixed-radius window of chunks alive around a focus
// point (typically the camera), spawns / despawns chunks at the
// edges, and exposes the visible set for the renderer to walk.
//
// The streamer is intentionally synchronous + Wren-side: each
// frame's `update(focusX, focusZ)` runs the load / unload diff
// inline, building meshes on demand and disposing leaving
// chunks. For massive worlds where chunk loads would spike the
// frame, swap in a fiber-driven async streamer wrapping the same
// chunk-by-chunk API — `@hatch:assets` `AssetLoader` is the
// obvious composition target.
//
// ## Example
//
// ```wren
// var streamer = TerrainStreamer.new(g.device, {
//   "chunkSize":   64,          // world units per chunk
//   "resolution":  33,          // verts per chunk side (32 quads)
//   "radius":      2,           // load chunks within 2 of focus
//   "heightSampler": Fn.new {|wx, wz|
//     return Noise.fbm2(wx * 0.01, wz * 0.01, 1337, 5, 2.0, 0.5) * 12.0
//   }
// })
// // Per frame:
// streamer.update(camera.x, camera.z)
// for (chunk in streamer.activeChunks) renderer.draw(chunk.mesh, chunk.material, chunk.modelMatrix)
// ```

import "./terrain" for Terrain

/// One terrain tile. Owns its mesh + bookkeeping for the
/// streamer's load / unload diff.
class TerrainChunk {
  /// Build a chunk at integer cell coords `(ix, iz)` with the
  /// given world-space size and per-side vertex resolution. The
  /// caller-supplied `heightSampler` is invoked at every vertex
  /// — pass a noise / heightmap closure that's deterministic
  /// in `(worldX, worldZ)` so neighbouring chunks share their
  /// boundary vertex heights and seams stay tight.
  ///
  /// @param {Device} device
  /// @param {Num} ix      Chunk-grid X coord.
  /// @param {Num} iz      Chunk-grid Z coord.
  /// @param {Num} size    World units per side.
  /// @param {Num} res     Verts per side. >= 2.
  /// @param {Fn}  heightSampler  `Fn.new {|wx, wz| height}`.
  construct new(device, ix, iz, size, res, heightSampler) {
    if (res < 2) Fiber.abort("TerrainChunk.new: res must be >= 2")
    _ix   = ix
    _iz   = iz
    _size = size
    _res  = res
    var heights = Float32Array.new(res * res)
    var minX = ix * size
    var minZ = iz * size
    var step = size / (res - 1)
    var j = 0
    while (j < res) {
      var wz = minZ + j * step
      var i = 0
      while (i < res) {
        var wx = minX + i * step
        heights[j * res + i] = heightSampler.call(wx, wz)
        i = i + 1
      }
      j = j + 1
    }
    _heights = heights
    _mesh = Terrain.meshFromHeightmap(device, heights, res, res, {
      "stepX":   step,
      "stepZ":   step,
      "originX": minX,
      "originZ": minZ
    })
    _alive = true
  }

  /// Chunk-grid X coord. @returns {Num}
  ix       { _ix }
  /// Chunk-grid Z coord. @returns {Num}
  iz       { _iz }
  /// World-space size per side. @returns {Num}
  size     { _size }
  /// Per-side vertex resolution. @returns {Num}
  res      { _res }
  /// Backing heightmap (`res * res` row-major). @returns {Float32Array}
  heights  { _heights }
  /// GPU Mesh built from the heightmap. @returns {Mesh}
  mesh     { _mesh }
  /// True until [destroy] has been called.
  isAlive  { _alive }
  /// World-space chunk-centre X. @returns {Num}
  centreX  { (_ix + 0.5) * _size }
  /// World-space chunk-centre Z. @returns {Num}
  centreZ  { (_iz + 0.5) * _size }

  /// Release the GPU mesh. Idempotent.
  destroy {
    if (!_alive) return
    _mesh.destroy
    _alive = false
  }

  toString { "TerrainChunk(%(_ix),%(_iz))" }
}

/// Chunk-grid streamer. Keeps a fixed-radius window of
/// TerrainChunks alive around a moving focus point; spawns new
/// chunks as the focus enters their region, destroys chunks the
/// focus has left behind.
///
/// All work happens inline on the calling thread. For
/// budget-bound frames the caller can rate-limit by passing a
/// `maxLoadsPerUpdate` knob and accepting eventually-consistent
/// boundary chunks (see [update]).
class TerrainStreamer {
  /// Build a streamer.
  ///
  /// | Option           | Type   | Default | Notes                                            |
  /// |------------------|--------|---------|--------------------------------------------------|
  /// | `chunkSize`      | `Num`  | `64`    | World units per chunk side.                      |
  /// | `resolution`     | `Num`  | `33`    | Verts per chunk side (32 quads).                 |
  /// | `radius`         | `Num`  | `2`     | Load chunks within this Chebyshev radius.        |
  /// | `heightSampler`  | `Fn`   | required | `Fn.new {\|wx, wz\| height}`. Must be deterministic so seams match. |
  /// | `maxLoadsPerUpdate` | `Num` | `0`   | If > 0, cap chunk builds per `update` call so a player teleport doesn't spike the frame. 0 disables (synchronous catch-up). |
  ///
  /// @param {Device} device
  /// @param {Map} opts
  construct new(device, opts) {
    if (opts == null) Fiber.abort("TerrainStreamer.new: opts is required")
    var sampler = opts["heightSampler"]
    if (sampler == null) Fiber.abort("TerrainStreamer.new: opts.heightSampler is required")
    _device           = device
    _chunkSize        = opts.containsKey("chunkSize")  ? opts["chunkSize"]  : 64
    _resolution       = opts.containsKey("resolution") ? opts["resolution"] : 33
    _radius           = opts.containsKey("radius")     ? opts["radius"]     : 2
    _sampler          = sampler
    _maxLoadsPerUpdate = opts.containsKey("maxLoadsPerUpdate") ? opts["maxLoadsPerUpdate"] : 0
    _chunks    = {}    // "ix:iz" → TerrainChunk
    _focusCell = null  // [ix, iz] of last focus position; null = first call
  }

  /// World units per chunk side. @returns {Num}
  chunkSize     { _chunkSize }
  /// Verts per chunk side. @returns {Num}
  resolution    { _resolution }
  /// Load radius (Chebyshev). @returns {Num}
  radius        { _radius }
  /// Live chunks (unordered). @returns {Sequence}
  activeChunks  { _chunks.values }
  /// Live chunk count. @returns {Num}
  count         { _chunks.count }

  /// Walk `(focusX, focusZ)` to its containing chunk cell, then
  /// load every cell within `radius` (Chebyshev distance — a
  /// `2r+1`-square window) and unload everything outside it.
  ///
  /// If `maxLoadsPerUpdate > 0`, the spawn list is sorted by
  /// distance from the focus and only the closest N chunks are
  /// built this call; remaining chunks land on subsequent
  /// updates, so the load cost is spread across frames at the
  /// price of a transient gap at the edge.
  ///
  /// @param {Num} focusX
  /// @param {Num} focusZ
  update(focusX, focusZ) {
    var fx = (focusX / _chunkSize).floor
    var fz = (focusZ / _chunkSize).floor
    _focusCell = [fx, fz]

    // 1. Unload chunks outside the window.
    var toUnload = []
    for (key in _chunks.keys) {
      var c = _chunks[key]
      var dx = c.ix - fx
      if (dx < 0) dx = -dx
      var dz = c.iz - fz
      if (dz < 0) dz = -dz
      if (dx > _radius || dz > _radius) toUnload.add(key)
    }
    for (key in toUnload) {
      _chunks[key].destroy
      _chunks.remove(key)
    }

    // 2. Collect spawn candidates (cells inside the window we
    //    don't already hold) along with their squared distance
    //    from the focus.
    var wanted = []
    var z = fz - _radius
    while (z <= fz + _radius) {
      var x = fx - _radius
      while (x <= fx + _radius) {
        var key = "%(x):%(z)"
        if (!_chunks.containsKey(key)) {
          var dx = x - fx
          var dz = z - fz
          wanted.add([dx * dx + dz * dz, x, z])
        }
        x = x + 1
      }
      z = z + 1
    }
    if (wanted.count == 0) return

    // 3. Sort by ascending distance — closest first, so a
    //    capped-budget update still gets the visible centre.
    insertionSort_(wanted)

    var budget = _maxLoadsPerUpdate > 0 ? _maxLoadsPerUpdate : wanted.count
    var spawned = 0
    var k = 0
    while (k < wanted.count && spawned < budget) {
      var entry = wanted[k]
      var x = entry[1]
      var z = entry[2]
      _chunks["%(x):%(z)"] = TerrainChunk.new(_device, x, z, _chunkSize, _resolution, _sampler)
      spawned = spawned + 1
      k = k + 1
    }
  }

  /// Insertion sort of `[dSq, ix, iz]` triples by ascending dSq.
  /// `(2r+1)²` entries — at radius 4 that's 81; insertion sort
  /// wins against quicksort's overhead on these sizes.
  insertionSort_(arr) {
    var i = 1
    while (i < arr.count) {
      var pivot = arr[i]
      var j = i - 1
      while (j >= 0 && arr[j][0] > pivot[0]) {
        arr[j + 1] = arr[j]
        j = j - 1
      }
      arr[j + 1] = pivot
      i = i + 1
    }
  }

  /// Destroy every live chunk. Use between scene loads.
  clear() {
    for (c in _chunks.values) c.destroy
    _chunks = {}
    _focusCell = null
  }
}
