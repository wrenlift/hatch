// `@hatch:spatial`. Spatial acceleration structures for 3D
// procedural worlds. Two complementary shapes ship today:
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
// Both store points keyed by caller-supplied numeric ids. Storing
// AABBs / arbitrary shapes is a planned extension; for now the
// caller inflates query radii to cover an entity's bounds.
// BVH (ray cast acceleration) and Quadtree (2D variant) land in
// follow-up releases.

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
