Spatial acceleration structures for 3D procedural worlds. Insert points, query by radius or AABB in single-digit microseconds. Pure Wren, no plugin — composes with `@hatch:gpu`'s `Frustum` + `Lod` for cull and LOD pipelines, and with `@hatch:noise` for density sampling.

## Overview

```wren
import "@hatch:spatial" for ClusterGrid, Octree

// Uniform 3D bucket grid — cheap insert, O(1) cell lookup. Best
// when entity density is roughly uniform across the world.
var grid = ClusterGrid.new(-128, -64, -128, 128, 64, 128, 4.0)
grid.insert(0, x, y, z)
grid.queryRadius(camX, camY, camZ, viewDist) {|id, ix, iy, iz|
  // hot path — runs once per hit, no allocation
  drawEntity(id)
}

// Adaptive octree — handles wildly varying density (cities beside
// open fields) without allocating buckets for empty regions.
var tree = Octree.new(-256, -64, -256, 256, 64, 256, 16)
tree.insert(0, x, y, z)
tree.queryAabb(minX, minY, minZ, maxX, maxY, maxZ) {|id, ix, iy, iz| ... }
```

## When to pick which

| | `ClusterGrid` | `Octree` |
|---|---|---|
| Build cost | `O(1)` per insert | `O(log n)` per insert + occasional rebalance |
| Query cost | `O(cells × entities/cell)` | `O(log n + hits)` |
| Memory | `O(populated cells × bucket capacity)` | `O(n)` |
| Best for | Uniform density: particle index, foliage scatter on flat terrain | Wildly varying density: city blocks, cluster + voids |
| Degenerate inputs | Clamp to boundary cell | Stays a leaf once span < 1e-6 |

Both expose the same callback contract: `cb(id, x, y, z)`. Return `false` from the callback to short-circuit the walk.

## Composition

Spatial structures are the connective tissue for the procedural-world pipeline:

- **`@hatch:noise`** drives placement: sample density, decide which grid cells get foliage, store the ids in a `ClusterGrid` or `Octree`.
- **`@hatch:gpu`'s `Frustum`** is the per-frame visibility test — query the spatial structure by the camera AABB, then run `Frustum.sphereVisible` on each hit.
- **`@hatch:gpu`'s `Lod`** classifies survivors by distance — push each into the right LOD bucket's instance buffer.

## Planned

- `Quadtree` — 2D variant for top-down scenes
- `BVH` — bounding-volume hierarchy for ray-cast acceleration

## Compatibility

Wren 0.4 and WrenLift runtime 0.1 or newer. Pure Wren, no transitive deps.
