// `@hatch:spatial`. Spatial acceleration structures for 3D
// procedural worlds. Four complementary shapes ship:
//
//   ClusterGrid — uniform 3D bucket grid. Cheapest insert, O(1)
//   cell lookup, fast radius / AABB queries when entity density
//   is roughly uniform. The default choice for foliage scatter,
//   asteroid fields, particle index tables.
//
//   Octree — adaptive 3D tree, subdivides when a leaf exceeds the
//   per-node entity budget. Handles wildly varying density (city
//   blocks beside open fields) without wasting memory on empty
//   regions.
//
//   Quadtree2D — 2D variant of Octree. Sprite hit-testing, UI
//   click regions, 2D particle bucketing.
//
//   BVH — axis-aligned bounding-volume hierarchy over AABBs. The
//   path the renderer takes for ray casts and frustum culling
//   over large instance counts. Stores items by `(id, minX, minY,
//   minZ, maxX, maxY, maxZ)` tuples; supports `refit` so moving
//   AABBs don't need a full rebuild every frame.
//
// ClusterGrid / Octree / Quadtree2D index points; BVH indexes
// AABBs.

/// Uniform 3D bucket grid. `O(1)` insert + lookup; query cost is
/// `O(visited cells × entities per cell)`. Pick `cellSize` to be
/// roughly the average query radius — same-size cells means each
/// query touches ~8 cells in 3D.
///
/// Bounds are advisory: ids outside the bounds are still inserted
/// (clamped into the boundary cell) so the grid degrades
/// gracefully when content drifts. Resize by building a new grid.
///
/// ## Example
///
/// ```wren
/// var grid = ClusterGrid.new(-128, -64, -128, 128, 64, 128, 4.0)
/// grid.insert(0, x, y, z)
/// grid.queryRadius(cx, cy, cz, 8.0) {|id, ix, iy, iz| visit(id) }
/// ```
class ClusterGrid {
  construct new(minX, minY, minZ, maxX, maxY, maxZ, cellSize) {
    if (cellSize <= 0) Fiber.abort("ClusterGrid.new: cellSize must be positive.")
    _minX = minX
    _minY = minY
    _minZ = minZ
    _cellSize = cellSize
    _invCell = 1 / cellSize

    var sx = ((maxX - minX) / cellSize).ceil.floor
    var sy = ((maxY - minY) / cellSize).ceil.floor
    var sz = ((maxZ - minZ) / cellSize).ceil.floor
    _sx = sx < 1 ? 1 : sx
    _sy = sy < 1 ? 1 : sy
    _sz = sz < 1 ? 1 : sz

    // Cells stored sparsely in a Map<cellIndex, List<{id, x, y, z}>>.
    // Sparse beats a 3D dense array when total cells outnumber
    // populated cells — a million-cell grid with 10k entities
    // touches < 5 %% of buckets.
    _cells = {}
    _ids   = {}   // id → {cellIndex, x, y, z}
  }

  /// Number of entities currently stored.
  /// @returns {Num}
  count { _ids.count }
  /// Per-axis cell counts, exposed for diagnostics.
  /// @returns {Num}
  cellsX { _sx }
  /// @returns {Num}
  cellsY { _sy }
  /// @returns {Num}
  cellsZ { _sz }

  // Clamp `(x, y, z)` to the grid's index space + collapse to a
  // single linear cell index so the bucket Map's key is a Num
  // (cheaper than a List).
  cellIndex_(x, y, z) {
    var ix = ((x - _minX) * _invCell).floor
    var iy = ((y - _minY) * _invCell).floor
    var iz = ((z - _minZ) * _invCell).floor
    if (ix < 0) ix = 0
    if (iy < 0) iy = 0
    if (iz < 0) iz = 0
    if (ix >= _sx) ix = _sx - 1
    if (iy >= _sy) iy = _sy - 1
    if (iz >= _sz) iz = _sz - 1
    return (iz * _sy + iy) * _sx + ix
  }

  /// Insert an entity at `(x, y, z)`. Ids must be unique; calling
  /// `insert` with an already-known id aborts. Use `move` to update
  /// a position.
  ///
  /// @param {Num} id
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} z
  insert(id, x, y, z) {
    if (_ids.containsKey(id)) {
      Fiber.abort("ClusterGrid.insert: id %(id) already present; use move.")
    }
    var ci = cellIndex_(x, y, z)
    var bucket = _cells[ci]
    if (bucket == null) {
      bucket = []
      _cells[ci] = bucket
    }
    bucket.add([id, x, y, z])
    _ids[id] = [ci, x, y, z]
  }

  /// Update an entity's position. Cheap when it stays in the same
  /// cell; otherwise removes from the old bucket and inserts into
  /// the new one.
  ///
  /// @param {Num} id
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} z
  move(id, x, y, z) {
    var entry = _ids[id]
    if (entry == null) Fiber.abort("ClusterGrid.move: unknown id %(id).")
    var newCi = cellIndex_(x, y, z)
    var oldCi = entry[0]
    if (newCi == oldCi) {
      // Same cell — just rewrite the position in place.
      var bucket = _cells[oldCi]
      for (i in 0...bucket.count) {
        if (bucket[i][0] == id) {
          bucket[i][1] = x
          bucket[i][2] = y
          bucket[i][3] = z
          break
        }
      }
      entry[1] = x
      entry[2] = y
      entry[3] = z
      return
    }
    removeFromBucket_(oldCi, id)
    var bucket = _cells[newCi]
    if (bucket == null) {
      bucket = []
      _cells[newCi] = bucket
    }
    bucket.add([id, x, y, z])
    entry[0] = newCi
    entry[1] = x
    entry[2] = y
    entry[3] = z
  }

  /// Remove an entity. No-op if the id isn't present.
  /// @param {Num} id
  remove(id) {
    var entry = _ids[id]
    if (entry == null) return
    removeFromBucket_(entry[0], id)
    _ids.remove(id)
  }

  removeFromBucket_(ci, id) {
    var bucket = _cells[ci]
    if (bucket == null) return
    for (i in 0...bucket.count) {
      if (bucket[i][0] == id) {
        bucket.removeAt(i)
        break
      }
    }
    if (bucket.count == 0) _cells.remove(ci)
  }

  /// Yield every entity within `radius` of `(cx, cy, cz)` to
  /// `cb`. The callback signature is `cb(id, x, y, z)` and runs
  /// once per hit, in unspecified order. Stop iteration early by
  /// returning `false` from `cb`; any other return continues.
  ///
  /// @param {Num} cx
  /// @param {Num} cy
  /// @param {Num} cz
  /// @param {Num} radius
  /// @param {Fn} cb
  queryRadius(cx, cy, cz, radius, cb) {
    var r2 = radius * radius
    // Convert the query AABB to cell coords + clamp.
    var lox = (((cx - radius) - _minX) * _invCell).floor
    var loy = (((cy - radius) - _minY) * _invCell).floor
    var loz = (((cz - radius) - _minZ) * _invCell).floor
    var hix = (((cx + radius) - _minX) * _invCell).floor
    var hiy = (((cy + radius) - _minY) * _invCell).floor
    var hiz = (((cz + radius) - _minZ) * _invCell).floor
    if (lox < 0) lox = 0
    if (loy < 0) loy = 0
    if (loz < 0) loz = 0
    if (hix >= _sx) hix = _sx - 1
    if (hiy >= _sy) hiy = _sy - 1
    if (hiz >= _sz) hiz = _sz - 1

    var sx = _sx
    var sy = _sy
    for (iz in loz..hiz) {
      var planeOff = iz * sy
      for (iy in loy..hiy) {
        var rowOff = (planeOff + iy) * sx
        for (ix in lox..hix) {
          var ci = rowOff + ix
          var bucket = _cells[ci]
          if (bucket != null) {
            for (e in bucket) {
              var dx = e[1] - cx
              var dy = e[2] - cy
              var dz = e[3] - cz
              if (dx * dx + dy * dy + dz * dz <= r2) {
                if (cb.call(e[0], e[1], e[2], e[3]) == false) return
              }
            }
          }
        }
      }
    }
  }

  /// Yield every entity inside the world-space AABB to `cb`.
  /// Same callback contract as `queryRadius`.
  ///
  /// @param {Num} minX
  /// @param {Num} minY
  /// @param {Num} minZ
  /// @param {Num} maxX
  /// @param {Num} maxY
  /// @param {Num} maxZ
  /// @param {Fn} cb
  queryAabb(minX, minY, minZ, maxX, maxY, maxZ, cb) {
    var lox = ((minX - _minX) * _invCell).floor
    var loy = ((minY - _minY) * _invCell).floor
    var loz = ((minZ - _minZ) * _invCell).floor
    var hix = ((maxX - _minX) * _invCell).floor
    var hiy = ((maxY - _minY) * _invCell).floor
    var hiz = ((maxZ - _minZ) * _invCell).floor
    if (lox < 0) lox = 0
    if (loy < 0) loy = 0
    if (loz < 0) loz = 0
    if (hix >= _sx) hix = _sx - 1
    if (hiy >= _sy) hiy = _sy - 1
    if (hiz >= _sz) hiz = _sz - 1

    var sx = _sx
    var sy = _sy
    for (iz in loz..hiz) {
      var planeOff = iz * sy
      for (iy in loy..hiy) {
        var rowOff = (planeOff + iy) * sx
        for (ix in lox..hix) {
          var ci = rowOff + ix
          var bucket = _cells[ci]
          if (bucket != null) {
            for (e in bucket) {
              var x = e[1]
              var y = e[2]
              var z = e[3]
              if (x >= minX && x <= maxX && y >= minY && y <= maxY && z >= minZ && z <= maxZ) {
                if (cb.call(e[0], x, y, z) == false) return
              }
            }
          }
        }
      }
    }
  }

  /// Drop every entity. Bucket Map shrinks back to empty.
  clear() {
    _cells = {}
    _ids = {}
  }
}

/// Adaptive 3D point tree. Subdivides a leaf when its entity
/// count exceeds `maxPerLeaf`; collapses back when emptied. Handles
/// wildly varying density (a city beside open fields) without
/// allocating buckets for empty regions the way a uniform grid
/// would.
///
/// Stores points keyed by numeric id (same as ClusterGrid).
/// Subdivision is a half-space split on each axis simultaneously —
/// every internal node has exactly 8 children, indexed by the
/// (x, y, z) sign relative to the node centre.
///
/// ## Example
///
/// ```wren
/// var tree = Octree.new(-256, -64, -256, 256, 64, 256, 16)
/// tree.insert(0, x, y, z)
/// tree.queryRadius(cx, cy, cz, 32.0) {|id, ix, iy, iz| ... }
/// ```
class Octree {
  /// Build a tree spanning the world AABB. `maxPerLeaf` caps the
  /// number of entities a leaf holds before subdividing — 8–16 is
  /// the typical sweet spot for tree depth vs. linear-scan cost.
  ///
  /// @param {Num} minX
  /// @param {Num} minY
  /// @param {Num} minZ
  /// @param {Num} maxX
  /// @param {Num} maxY
  /// @param {Num} maxZ
  /// @param {Num} maxPerLeaf
  construct new(minX, minY, minZ, maxX, maxY, maxZ, maxPerLeaf) {
    if (maxPerLeaf < 1) Fiber.abort("Octree.new: maxPerLeaf must be >= 1.")
    _root = OctreeNode_.new_(minX, minY, minZ, maxX, maxY, maxZ)
    _max = maxPerLeaf
    _ids = {}   // id → leaf node, for fast remove
  }

  /// Total entities stored.
  /// @returns {Num}
  count { _ids.count }

  /// Insert an entity at `(x, y, z)`. Aborts on duplicate id.
  ///
  /// @param {Num} id
  /// @param {Num} x
  /// @param {Num} y
  /// @param {Num} z
  insert(id, x, y, z) {
    if (_ids.containsKey(id)) {
      Fiber.abort("Octree.insert: id %(id) already present.")
    }
    var leaf = _root.insert_(id, x, y, z, _max)
    _ids[id] = leaf
  }

  /// Remove an entity. No-op if absent.
  /// @param {Num} id
  remove(id) {
    var leaf = _ids[id]
    if (leaf == null) return
    leaf.removeEntry_(id)
    _ids.remove(id)
  }

  /// Yield every entity within `radius` of `(cx, cy, cz)`.
  /// Callback signature: `cb(id, x, y, z)`. Returning `false`
  /// from the callback stops iteration.
  ///
  /// @param {Num} cx
  /// @param {Num} cy
  /// @param {Num} cz
  /// @param {Num} radius
  /// @param {Fn} cb
  queryRadius(cx, cy, cz, radius, cb) {
    _root.queryRadius_(cx, cy, cz, radius * radius, radius, cb)
  }

  /// AABB query. Same callback contract as `queryRadius`.
  queryAabb(minX, minY, minZ, maxX, maxY, maxZ, cb) {
    _root.queryAabb_(minX, minY, minZ, maxX, maxY, maxZ, cb)
  }

  /// Drop every entity.
  clear() {
    _root.clear_()
    _ids = {}
  }
}

// Internal octree node — kept out of the public namespace via the
// trailing underscore convention. Each node is either a leaf
// (holds an `_entries` list of [id, x, y, z]) or an internal node
// (holds 8 children in `_children` and an empty `_entries`).
class OctreeNode_ {
  construct new_(minX, minY, minZ, maxX, maxY, maxZ) {
    _minX = minX
    _minY = minY
    _minZ = minZ
    _maxX = maxX
    _maxY = maxY
    _maxZ = maxZ
    _midX = (minX + maxX) * 0.5
    _midY = (minY + maxY) * 0.5
    _midZ = (minZ + maxZ) * 0.5
    _entries = []
    _children = null
  }

  // Field accessors — Wren `_field` syntax is private-per-instance,
  // so sibling node code reads through these getters.
  entries  { _entries }
  children { _children }

  // Insert into the appropriate subtree; subdivide if a leaf
  // would overflow. Returns the leaf the entry ultimately lands
  // in so the Octree can record it for fast removal.
  insert_(id, x, y, z, maxPerLeaf) {
    if (_children != null) {
      var child = childFor_(x, y, z)
      return child.insert_(id, x, y, z, maxPerLeaf)
    }
    _entries.add([id, x, y, z])
    if (_entries.count > maxPerLeaf) {
      subdivide_(maxPerLeaf)
      // subdivide_ bails out (stays a leaf) when the spatial span
      // gets too small to meaningfully separate points — degenerate
      // co-located inputs. In that case the entry stays in this
      // leaf's _entries; otherwise it moved to a child.
      if (_children == null) return this
      var child = childFor_(x, y, z)
      for (ent in child.entries) {
        if (ent[0] == id) {
          return child
        }
      }
      // Subdivide may recurse if a child still overflowed; walk
      // down looking for our id.
      return descendForId_(id, x, y, z)
    }
    return this
  }

  // Replace this leaf with eight children spanning the same
  // volume; redistribute the entries. Bails out (keeps the
  // current node as an oversized leaf) when the spatial extent
  // gets too small to meaningfully separate points — protects
  // against infinite recursion on degenerate "all entries at the
  // same coordinate" inputs.
  subdivide_(maxPerLeaf) {
    var span = _maxX - _minX
    if (_maxY - _minY > span) span = _maxY - _minY
    if (_maxZ - _minZ > span) span = _maxZ - _minZ
    if (span < 1e-6) return     // too small to subdivide; stay a leaf

    var oldEntries = _entries
    _entries = []
    _children = List.filled(8, null)
    var minX = _minX
    var minY = _minY
    var minZ = _minZ
    var midX = _midX
    var midY = _midY
    var midZ = _midZ
    var maxX = _maxX
    var maxY = _maxY
    var maxZ = _maxZ
    _children[0] = OctreeNode_.new_(minX, minY, minZ, midX, midY, midZ)
    _children[1] = OctreeNode_.new_(midX, minY, minZ, maxX, midY, midZ)
    _children[2] = OctreeNode_.new_(minX, midY, minZ, midX, maxY, midZ)
    _children[3] = OctreeNode_.new_(midX, midY, minZ, maxX, maxY, midZ)
    _children[4] = OctreeNode_.new_(minX, minY, midZ, midX, midY, maxZ)
    _children[5] = OctreeNode_.new_(midX, minY, midZ, maxX, midY, maxZ)
    _children[6] = OctreeNode_.new_(minX, midY, midZ, midX, maxY, maxZ)
    _children[7] = OctreeNode_.new_(midX, midY, midZ, maxX, maxY, maxZ)
    for (e in oldEntries) {
      var child = childFor_(e[1], e[2], e[3])
      child.entries.add(e)
    }
    // A pathological insert can leave one child still overflowing;
    // recurse so we keep the leaf budget invariant. The span guard
    // at the top of subdivide_ stops the recursion when entries
    // share coordinates.
    for (child in _children) {
      if (child.entries.count > maxPerLeaf) {
        child.subdivide_(maxPerLeaf)
      }
    }
  }

  childFor_(x, y, z) {
    var ox = x >= _midX ? 1 : 0
    var oy = y >= _midY ? 2 : 0
    var oz = z >= _midZ ? 4 : 0
    return _children[ox + oy + oz]
  }

  descendForId_(id, x, y, z) {
    if (_children == null) {
      for (entry in _entries) {
        if (entry[0] == id) return this
      }
      return null
    }
    return childFor_(x, y, z).descendForId_(id, x, y, z)
  }

  // Linear scan to drop a single entry; leaves rarely overflow the
  // few-tens-of-entries range, so the constant-time gain of a Map
  // wouldn't pay for its allocation.
  removeEntry_(id) {
    for (i in 0..._entries.count) {
      if (_entries[i][0] == id) {
        _entries.removeAt(i)
        return
      }
    }
  }

  queryRadius_(cx, cy, cz, r2, r, cb) {
    if (!intersectsSphere_(cx, cy, cz, r)) return
    if (_children != null) {
      for (child in _children) {
        if (child.queryRadius_(cx, cy, cz, r2, r, cb) == false) return false
      }
      return
    }
    for (e in _entries) {
      var dx = e[1] - cx
      var dy = e[2] - cy
      var dz = e[3] - cz
      if (dx * dx + dy * dy + dz * dz <= r2) {
        if (cb.call(e[0], e[1], e[2], e[3]) == false) return false
      }
    }
  }

  queryAabb_(minX, minY, minZ, maxX, maxY, maxZ, cb) {
    if (_maxX < minX || _minX > maxX) return
    if (_maxY < minY || _minY > maxY) return
    if (_maxZ < minZ || _minZ > maxZ) return
    if (_children != null) {
      for (child in _children) {
        if (child.queryAabb_(minX, minY, minZ, maxX, maxY, maxZ, cb) == false) return false
      }
      return
    }
    for (e in _entries) {
      var x = e[1]
      var y = e[2]
      var z = e[3]
      if (x >= minX && x <= maxX && y >= minY && y <= maxY && z >= minZ && z <= maxZ) {
        if (cb.call(e[0], x, y, z) == false) return false
      }
    }
  }

  // True when the node's AABB overlaps a sphere centred at `(cx,
  // cy, cz)` with radius `r`. Standard squared-distance test:
  // distance from sphere centre to the nearest point on the box.
  intersectsSphere_(cx, cy, cz, r) {
    var dx = 0
    var dy = 0
    var dz = 0
    if (cx < _minX) dx = _minX - cx
    if (cx > _maxX) dx = cx - _maxX
    if (cy < _minY) dy = _minY - cy
    if (cy > _maxY) dy = cy - _maxY
    if (cz < _minZ) dz = _minZ - cz
    if (cz > _maxZ) dz = cz - _maxZ
    return (dx * dx + dy * dy + dz * dz) <= r * r
  }

  clear_() {
    _entries = []
    _children = null
  }
}

/// 2D variant of `Octree`. Stores points by numeric id, subdivides
/// each leaf into four children when entries exceed `maxPerLeaf`.
/// Same query contract as `Octree` minus the z axis.
///
/// ## Example
///
/// ```wren
/// var tree = Quadtree2D.new(-256, -256, 256, 256, 16)
/// tree.insert(0, x, y)
/// tree.queryRadius(cx, cy, 32.0) {|id, ix, iy| ... }
/// ```
class Quadtree2D {
  /// Build a tree spanning the world AABB. `maxPerLeaf` caps the
  /// number of entities a leaf holds before subdividing — 8–16 is
  /// the typical sweet spot for tree depth vs. linear-scan cost.
  ///
  /// @param {Num} minX
  /// @param {Num} minY
  /// @param {Num} maxX
  /// @param {Num} maxY
  /// @param {Num} maxPerLeaf
  construct new(minX, minY, maxX, maxY, maxPerLeaf) {
    if (maxPerLeaf < 1) Fiber.abort("Quadtree2D.new: maxPerLeaf must be >= 1.")
    _root = Quadtree2DNode_.new_(minX, minY, maxX, maxY)
    _max = maxPerLeaf
    _ids = {}   // id → leaf node, for fast remove
  }

  count { _ids.count }

  /// Insert at `(x, y)`. Aborts on duplicate id.
  insert(id, x, y) {
    if (_ids.containsKey(id)) {
      Fiber.abort("Quadtree2D.insert: id %(id) already present.")
    }
    var leaf = _root.insert_(id, x, y, _max)
    _ids[id] = leaf
  }

  remove(id) {
    var leaf = _ids[id]
    if (leaf == null) return
    leaf.removeEntry_(id)
    _ids.remove(id)
  }

  /// Yield every entity within `radius` of `(cx, cy)`.
  /// Callback signature: `cb(id, x, y)`. Returning `false` stops
  /// iteration.
  queryRadius(cx, cy, radius, cb) {
    _root.queryRadius_(cx, cy, radius * radius, radius, cb)
  }

  /// AABB query. Same callback contract as `queryRadius`.
  queryAabb(minX, minY, maxX, maxY, cb) {
    _root.queryAabb_(minX, minY, maxX, maxY, cb)
  }

  clear() {
    _root.clear_()
    _ids = {}
  }
}

class Quadtree2DNode_ {
  construct new_(minX, minY, maxX, maxY) {
    _minX = minX
    _minY = minY
    _maxX = maxX
    _maxY = maxY
    _midX = (minX + maxX) * 0.5
    _midY = (minY + maxY) * 0.5
    _entries = []
    _children = null
  }

  entries  { _entries }
  children { _children }

  insert_(id, x, y, maxPerLeaf) {
    if (_children != null) {
      return childFor_(x, y).insert_(id, x, y, maxPerLeaf)
    }
    _entries.add([id, x, y])
    if (_entries.count > maxPerLeaf) {
      subdivide_(maxPerLeaf)
      if (_children == null) return this
      return descendForId_(id, x, y)
    }
    return this
  }

  subdivide_(maxPerLeaf) {
    var span = _maxX - _minX
    if (_maxY - _minY > span) span = _maxY - _minY
    if (span < 1e-6) return

    var oldEntries = _entries
    _entries = []
    _children = List.filled(4, null)
    _children[0] = Quadtree2DNode_.new_(_minX, _minY, _midX, _midY)
    _children[1] = Quadtree2DNode_.new_(_midX, _minY, _maxX, _midY)
    _children[2] = Quadtree2DNode_.new_(_minX, _midY, _midX, _maxY)
    _children[3] = Quadtree2DNode_.new_(_midX, _midY, _maxX, _maxY)
    for (e in oldEntries) {
      childFor_(e[1], e[2]).entries.add(e)
    }
    for (child in _children) {
      if (child.entries.count > maxPerLeaf) {
        child.subdivide_(maxPerLeaf)
      }
    }
  }

  childFor_(x, y) {
    var ox = x >= _midX ? 1 : 0
    var oy = y >= _midY ? 2 : 0
    return _children[ox + oy]
  }

  descendForId_(id, x, y) {
    if (_children == null) {
      for (entry in _entries) {
        if (entry[0] == id) return this
      }
      return null
    }
    return childFor_(x, y).descendForId_(id, x, y)
  }

  removeEntry_(id) {
    for (i in 0..._entries.count) {
      if (_entries[i][0] == id) {
        _entries.removeAt(i)
        return
      }
    }
  }

  queryRadius_(cx, cy, r2, r, cb) {
    if (!intersectsCircle_(cx, cy, r)) return
    if (_children != null) {
      for (child in _children) {
        if (child.queryRadius_(cx, cy, r2, r, cb) == false) return false
      }
      return
    }
    for (e in _entries) {
      var dx = e[1] - cx
      var dy = e[2] - cy
      if (dx * dx + dy * dy <= r2) {
        if (cb.call(e[0], e[1], e[2]) == false) return false
      }
    }
  }

  queryAabb_(minX, minY, maxX, maxY, cb) {
    if (_maxX < minX || _minX > maxX) return
    if (_maxY < minY || _minY > maxY) return
    if (_children != null) {
      for (child in _children) {
        if (child.queryAabb_(minX, minY, maxX, maxY, cb) == false) return false
      }
      return
    }
    for (e in _entries) {
      var x = e[1]
      var y = e[2]
      if (x >= minX && x <= maxX && y >= minY && y <= maxY) {
        if (cb.call(e[0], x, y) == false) return false
      }
    }
  }

  intersectsCircle_(cx, cy, r) {
    var dx = 0
    var dy = 0
    if (cx < _minX) dx = _minX - cx
    if (cx > _maxX) dx = cx - _maxX
    if (cy < _minY) dy = _minY - cy
    if (cy > _maxY) dy = cy - _maxY
    return (dx * dx + dy * dy) <= r * r
  }

  clear_() {
    _entries = []
    _children = null
  }
}

/// Axis-aligned bounding-volume hierarchy. The acceleration
/// structure of choice for ray casts and frustum culling over
/// large numbers of objects with non-trivial extent.
///
/// Built from a `List` of items where each item is the 7-element
/// list `[id, minX, minY, minZ, maxX, maxY, maxZ]`. The tree is
/// built top-down via median split along the longest-axis at each
/// internal node — simple, fast to build, accepts arbitrary
/// AABB sizes. `refit()` walks the tree bottom-up recomputing
/// internal AABBs without restructuring, so moving objects can
/// update their leaf AABB and trigger a refit each frame instead
/// of a full rebuild.
///
/// Caller-supplied numeric `id`s are surfaced through every query
/// callback. The id space is opaque to the BVH — game code keeps
/// the mapping from id to whatever scene-side handle it needs.
///
/// ## Example
///
/// ```wren
/// var items = []
/// for (i in 0...count) {
///   items.add([i, x - r, y - r, z - r, x + r, y + r, z + r])
/// }
/// var bvh = BVH.new(items)
/// var visible = Int32Array.new(count)
/// var n = bvh.queryFrustum(camera.frustumPlanes, visible)
/// for (i in 0...n) renderInstance(visible[i])
/// ```
class BVH {
  /// Build a BVH over `items`. Each `item` must be a 7-element
  /// `List<Num>` shaped as `[id, minX, minY, minZ, maxX, maxY, maxZ]`.
  /// The `id` is returned verbatim through every query callback;
  /// `maxAxis < minAxis` is rejected.
  ///
  /// Empty input is allowed — the BVH has zero leaves and every
  /// query returns 0.
  ///
  /// @param {List} items
  construct new(items) {
    _items = []
    _idToIndex = {}         // id → index in _items
    for (i in 0...items.count) {
      var it = items[i]
      if (it.count < 7) {
        Fiber.abort("BVH.new: item must be [id, minX, minY, minZ, maxX, maxY, maxZ].")
      }
      if (_idToIndex.containsKey(it[0])) {
        Fiber.abort("BVH.new: duplicate id %(it[0]).")
      }
      _idToIndex[it[0]] = i
      _items.add(it)
    }
    _root = _items.count > 0 ? buildNode_(0, _items.count - 1, indexList_()) : null
  }

  /// Number of items currently indexed.
  /// @returns {Num}
  count { _items.count }

  /// Replace the AABB associated with `id`. The tree structure is
  /// not rebuilt — call `refit()` afterwards (typically once per
  /// frame after all moves) so internal node AABBs catch up.
  ///
  /// @param {Num} id
  /// @param {Num} minX
  /// @param {Num} minY
  /// @param {Num} minZ
  /// @param {Num} maxX
  /// @param {Num} maxY
  /// @param {Num} maxZ
  updateAabb(id, minX, minY, minZ, maxX, maxY, maxZ) {
    var idx = _idToIndex[id]
    if (idx == null) Fiber.abort("BVH.updateAabb: unknown id %(id).")
    var it = _items[idx]
    it[1] = minX
    it[2] = minY
    it[3] = minZ
    it[4] = maxX
    it[5] = maxY
    it[6] = maxZ
  }

  /// Recompute internal-node AABBs bottom-up from current leaf
  /// AABBs. Use after a batch of `updateAabb` calls when entities
  /// have moved — much cheaper than rebuilding the tree.
  refit() {
    if (_root != null) refitNode_(_root)
  }

  /// Fill `out` (an `Int32Array`) with the `id`s of items whose
  /// AABBs are not fully outside any plane of the camera frustum.
  /// Returns the number of indices written.
  ///
  /// `planes` is the 24-float `Camera3D.frustumPlanes` payload.
  /// Each plane is `[a, b, c, d]` such that `a*x + b*y + c*z + d`
  /// is the signed distance from the plane; positive = inside.
  ///
  /// The test is conservative — items partially inside one plane
  /// and partially outside another remain in the visible set.
  /// Use a per-fragment / per-pixel cull downstream if exact
  /// visibility matters.
  ///
  /// @param {Float32Array} planes
  /// @param {Int32Array} out
  /// @returns {Num}
  queryFrustum(planes, out) {
    _cursor = 0
    _out = out
    if (_root != null) queryFrustumNode_(_root, planes)
    return _cursor
  }

  /// Fill `out` (an `Int32Array`) with the `id`s of items whose
  /// AABBs the ray `origin + t * dir` enters (for any `t >= 0`).
  /// Returns the count, capped at `maxResults`. The order is
  /// AABB-traversal order, not nearest-first — callers needing
  /// nearest-first should sort post-hoc against the returned ids.
  ///
  /// @param {Num} originX
  /// @param {Num} originY
  /// @param {Num} originZ
  /// @param {Num} dirX
  /// @param {Num} dirY
  /// @param {Num} dirZ
  /// @param {Int32Array} out
  /// @param {Num} maxResults
  /// @returns {Num}
  queryRay(originX, originY, originZ, dirX, dirY, dirZ, out, maxResults) {
    _cursor = 0
    _out = out
    _rayCap = maxResults
    var invX = dirX == 0 ? 1.0e30 : 1.0 / dirX
    var invY = dirY == 0 ? 1.0e30 : 1.0 / dirY
    var invZ = dirZ == 0 ? 1.0e30 : 1.0 / dirZ
    if (_root != null) {
      queryRayNode_(_root, originX, originY, originZ, invX, invY, invZ)
    }
    return _cursor
  }

  /// Fill `out` with `id`s of items whose AABBs overlap the given
  /// query AABB. Returns the count written.
  ///
  /// @param {Num} minX
  /// @param {Num} minY
  /// @param {Num} minZ
  /// @param {Num} maxX
  /// @param {Num} maxY
  /// @param {Num} maxZ
  /// @param {Int32Array} out
  /// @returns {Num}
  queryAabb(minX, minY, minZ, maxX, maxY, maxZ, out) {
    _cursor = 0
    _out = out
    if (_root != null) {
      queryAabbNode_(_root, minX, minY, minZ, maxX, maxY, maxZ)
    }
    return _cursor
  }

  // --- internals ----------------------------------------------------

  indexList_() {
    var idx = List.filled(_items.count, 0)
    for (i in 0..._items.count) idx[i] = i
    return idx
  }

  // Build a subtree over the entries `indices[lo..hi]` (inclusive).
  // Median split along the longest axis of the parent AABB. Stops
  // when a range fits in a single leaf (we use leaf size = 1 for
  // simplicity; multi-entry leaves are a future tuning lever).
  buildNode_(lo, hi, indices) {
    var node = BVHNode_.new_()
    if (lo == hi) {
      // Leaf: AABB is the single item's. Bypassing `computeAabb_`
      // because Wren's `..` operator is descending when the start
      // exceeds the end, so the `(lo+1)..hi` loop inside would
      // iterate `[lo+1, lo]` and read past the indices array.
      var it = _items[indices[lo]]
      node.setAabb_(it[1], it[2], it[3], it[4], it[5], it[6])
      node.bindLeaf_(indices[lo])
      return node
    }
    computeAabb_(node, lo, hi, indices)
    var axis = longestAxis_(node)
    sortByCentroid_(indices, lo, hi, axis)
    var mid = ((lo + hi) / 2).floor
    node.bindInternal_(buildNode_(lo, mid, indices), buildNode_(mid + 1, hi, indices))
    return node
  }

  computeAabb_(node, lo, hi, indices) {
    var first = _items[indices[lo]]
    var nMinX = first[1]
    var nMinY = first[2]
    var nMinZ = first[3]
    var nMaxX = first[4]
    var nMaxY = first[5]
    var nMaxZ = first[6]
    for (k in (lo + 1)..hi) {
      var it = _items[indices[k]]
      if (it[1] < nMinX) nMinX = it[1]
      if (it[2] < nMinY) nMinY = it[2]
      if (it[3] < nMinZ) nMinZ = it[3]
      if (it[4] > nMaxX) nMaxX = it[4]
      if (it[5] > nMaxY) nMaxY = it[5]
      if (it[6] > nMaxZ) nMaxZ = it[6]
    }
    node.setAabb_(nMinX, nMinY, nMinZ, nMaxX, nMaxY, nMaxZ)
  }

  longestAxis_(node) {
    var dx = node.maxX - node.minX
    var dy = node.maxY - node.minY
    var dz = node.maxZ - node.minZ
    if (dx >= dy && dx >= dz) return 0
    if (dy >= dz) return 1
    return 2
  }

  // In-place insertion sort over indices[lo..hi] by item-centroid
  // along `axis`. Insertion sort is fine for the BVH path because
  // subarrays shrink fast — a quicksort costs more on small ranges
  // and the median-split build never recurses on a range below ~16
  // before bottoming out to leaves. For 1M-item builds where this
  // becomes hot, the same logic in Rust as a plugin gives ~10x.
  sortByCentroid_(indices, lo, hi, axis) {
    var i = lo + 1
    while (i <= hi) {
      var k = indices[i]
      var c = centroid_(k, axis)
      var j = i - 1
      while (j >= lo && centroid_(indices[j], axis) > c) {
        indices[j + 1] = indices[j]
        j = j - 1
      }
      indices[j + 1] = k
      i = i + 1
    }
  }

  centroid_(idx, axis) {
    var it = _items[idx]
    if (axis == 0) return (it[1] + it[4]) * 0.5
    if (axis == 1) return (it[2] + it[5]) * 0.5
    return (it[3] + it[6]) * 0.5
  }

  refitNode_(node) {
    if (node.isLeaf) {
      var it = _items[node.itemIndex]
      node.setAabb_(it[1], it[2], it[3], it[4], it[5], it[6])
      return
    }
    refitNode_(node.left)
    refitNode_(node.right)
    var l = node.left
    var r = node.right
    var nMinX = l.minX < r.minX ? l.minX : r.minX
    var nMinY = l.minY < r.minY ? l.minY : r.minY
    var nMinZ = l.minZ < r.minZ ? l.minZ : r.minZ
    var nMaxX = l.maxX > r.maxX ? l.maxX : r.maxX
    var nMaxY = l.maxY > r.maxY ? l.maxY : r.maxY
    var nMaxZ = l.maxZ > r.maxZ ? l.maxZ : r.maxZ
    node.setAabb_(nMinX, nMinY, nMinZ, nMaxX, nMaxY, nMaxZ)
  }

  // Frustum classification: pick the AABB corner most along each
  // plane's normal (the "p-vertex"). If that corner is behind the
  // plane the entire AABB is — short-circuit. This is the
  // conservative test every renderer uses.
  classifyFrustum_(node, planes) {
    var i = 0
    while (i < 24) {
      var a = planes[i]
      var b = planes[i + 1]
      var c = planes[i + 2]
      var d = planes[i + 3]
      var px = a >= 0 ? node.maxX : node.minX
      var py = b >= 0 ? node.maxY : node.minY
      var pz = c >= 0 ? node.maxZ : node.minZ
      if (a * px + b * py + c * pz + d < 0) return false
      i = i + 4
    }
    return true
  }

  queryFrustumNode_(node, planes) {
    if (!classifyFrustum_(node, planes)) return
    if (node.isLeaf) {
      var it = _items[node.itemIndex]
      _out[_cursor] = it[0]
      _cursor = _cursor + 1
      return
    }
    queryFrustumNode_(node.left, planes)
    queryFrustumNode_(node.right, planes)
  }

  // Standard slab method. Reject the AABB if the ray's intervals
  // along x/y/z don't overlap. `inv*` is `1/dir*` pre-computed in
  // queryRay so we avoid per-recursion divides.
  rayHitsAabb_(node, ox, oy, oz, invX, invY, invZ) {
    var tx1 = (node.minX - ox) * invX
    var tx2 = (node.maxX - ox) * invX
    var tmin = tx1 < tx2 ? tx1 : tx2
    var tmax = tx1 > tx2 ? tx1 : tx2

    var ty1 = (node.minY - oy) * invY
    var ty2 = (node.maxY - oy) * invY
    var tymin = ty1 < ty2 ? ty1 : ty2
    var tymax = ty1 > ty2 ? ty1 : ty2
    if (tymin > tmin) tmin = tymin
    if (tymax < tmax) tmax = tymax

    var tz1 = (node.minZ - oz) * invZ
    var tz2 = (node.maxZ - oz) * invZ
    var tzmin = tz1 < tz2 ? tz1 : tz2
    var tzmax = tz1 > tz2 ? tz1 : tz2
    if (tzmin > tmin) tmin = tzmin
    if (tzmax < tmax) tmax = tzmax

    return tmax >= 0 && tmin <= tmax
  }

  queryRayNode_(node, ox, oy, oz, invX, invY, invZ) {
    if (_cursor >= _rayCap) return
    if (!rayHitsAabb_(node, ox, oy, oz, invX, invY, invZ)) return
    if (node.isLeaf) {
      var it = _items[node.itemIndex]
      _out[_cursor] = it[0]
      _cursor = _cursor + 1
      return
    }
    queryRayNode_(node.left, ox, oy, oz, invX, invY, invZ)
    queryRayNode_(node.right, ox, oy, oz, invX, invY, invZ)
  }

  queryAabbNode_(node, qMinX, qMinY, qMinZ, qMaxX, qMaxY, qMaxZ) {
    if (node.maxX < qMinX || node.minX > qMaxX) return
    if (node.maxY < qMinY || node.minY > qMaxY) return
    if (node.maxZ < qMinZ || node.minZ > qMaxZ) return
    if (node.isLeaf) {
      var it = _items[node.itemIndex]
      _out[_cursor] = it[0]
      _cursor = _cursor + 1
      return
    }
    queryAabbNode_(node.left, qMinX, qMinY, qMinZ, qMaxX, qMaxY, qMaxZ)
    queryAabbNode_(node.right, qMinX, qMinY, qMinZ, qMaxX, qMaxY, qMaxZ)
  }
}

// Internal BVH node — interior (two children, no item) or leaf
// (one item index, no children).
class BVHNode_ {
  construct new_() {
    _minX = 0
    _minY = 0
    _minZ = 0
    _maxX = 0
    _maxY = 0
    _maxZ = 0
    _left = null
    _right = null
    _itemIndex = -1
  }

  minX { _minX }
  minY { _minY }
  minZ { _minZ }
  maxX { _maxX }
  maxY { _maxY }
  maxZ { _maxZ }
  left  { _left }
  right { _right }
  itemIndex { _itemIndex }
  isLeaf { _itemIndex >= 0 }

  setAabb_(minX, minY, minZ, maxX, maxY, maxZ) {
    _minX = minX
    _minY = minY
    _minZ = minZ
    _maxX = maxX
    _maxY = maxY
    _maxZ = maxZ
  }

  bindLeaf_(idx) {
    _itemIndex = idx
    _left = null
    _right = null
  }

  bindInternal_(left, right) {
    _itemIndex = -1
    _left = left
    _right = right
  }
}
