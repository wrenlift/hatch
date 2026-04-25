// @hatch:ecs — thin entity / component / system store.
//
//   import "@hatch:ecs" for World
//
//   class Position { construct new(x, y) { _x = x; _y = y }; ... }
//   class Velocity { construct new(x, y) { _x = x; _y = y }; ... }
//   class Sprite   { construct new(image) { _image = image };  ... }
//
//   var world  = World.new()
//   var player = world.spawn()
//   world.attach(player, Position.new(100, 100))
//   world.attach(player, Velocity.new(50, 0))
//   world.attach(player, Sprite.new(heroTexture))
//
//   // A "system" is just a function over a query.
//   for (e in world.query([Position, Velocity])) {
//     var p = world.get(e, Position)
//     var v = world.get(e, Velocity)
//     p.x = p.x + v.x * dt
//     p.y = p.y + v.y * dt
//   }
//
// Entities are opaque ids (Num). Components are class instances —
// the component's runtime class is the storage key, so you don't
// need to register types up front. Query asks for a list of
// component classes; the result iterates the smallest matching
// pool and filters from there.
//
// Deliberately small surface:
//   - No archetype graphs, no SoA storage. Map<class, Map<id, instance>>
//     is the whole storage model. Plenty fast for the few thousand-
//     entity scale most 2D games run at.
//   - No system scheduler / runtime ordering. `world.query(...)` +
//     a loop is the entire system mechanism. Order = the order you
//     call your update functions.
//   - No events, no relationships, no commands buffer. Mutation
//     during iteration is allowed; spawning new entities mid-query
//     might or might not surface them this frame depending on the
//     iteration order.
//
// If those tradeoffs ever bite, switch up to a full ECS — the
// `World` class is small enough to extract data out of in one
// pass.

class World {
  construct new() {
    _nextId     = 1
    _entities   = {}     // id → true (set)
    _components = {}     // ComponentClass → { id → instance }
  }

  // Number of live entities.
  count { _entities.count }

  // Number of components currently registered for `klass`.
  countOf(klass) {
    if (!_components.containsKey(klass)) return 0
    return _components[klass].count
  }

  // Allocate a new entity id. Cheap; ids are monotonic numbers.
  spawn() {
    var id = _nextId
    _nextId = _nextId + 1
    _entities[id] = true
    return id
  }

  // Drop the entity and every component attached to it.
  // Idempotent — calling twice is a no-op.
  despawn(e) {
    if (!_entities.containsKey(e)) return
    _entities.remove(e)
    for (storage in _components.values) {
      if (storage.containsKey(e)) storage.remove(e)
    }
  }

  // Attach a component instance. The component's runtime class
  // (`component.type`) is the storage key. Returns the component
  // for chaining:
  //
  //   var p = world.attach(e, Position.new(0, 0))
  //   p.x = 100
  attach(e, component) {
    var klass = component.type
    if (!_components.containsKey(klass)) _components[klass] = {}
    _components[klass][e] = component
    return component
  }

  // Drop a component from an entity. Idempotent.
  detach(e, klass) {
    if (!_components.containsKey(klass)) return
    var storage = _components[klass]
    if (storage.containsKey(e)) storage.remove(e)
  }

  // True iff `e` has a component of class `klass`.
  has(e, klass) {
    if (!_components.containsKey(klass)) return false
    return _components[klass].containsKey(e)
  }

  // Read a component back. Returns null if the entity doesn't
  // have one of that class.
  get(e, klass) {
    if (!_components.containsKey(klass)) return null
    return _components[klass][e]
  }

  // Replace a component (calls attach). The previous instance
  // is dropped from the storage map.
  set(e, component) { attach(e, component) }

  // Iterate entity ids that have every class in `klasses`.
  // `klasses` may be:
  //   - empty → every live entity
  //   - one class → cheap; iterate that class's storage
  //   - many classes → iterate the smallest pool, filter by
  //     `containsKey` on the rest.
  //
  // Returns a fresh List you can iterate safely; the world's
  // own storage isn't exposed, so spawn / despawn during the
  // returned iteration is fine.
  query(klasses) {
    if (klasses.count == 0) {
      var out = []
      for (id in _entities.keys) out.add(id)
      return out
    }
    // Find the smallest class storage to use as the iteration
    // pivot. Empty storage anywhere → no matches.
    var smallest = null
    var smallestSize = -1
    for (k in klasses) {
      if (!_components.containsKey(k)) return []
      var size = _components[k].count
      if (smallestSize < 0 || size < smallestSize) {
        smallestSize = size
        smallest = _components[k]
      }
    }
    var out = []
    for (id in smallest.keys) {
      var ok = true
      for (k in klasses) {
        if (!_components[k].containsKey(id)) {
          ok = false
          break
        }
      }
      if (ok) out.add(id)
    }
    return out
  }

  // Convenience for the common "iterate every entity that has
  // these components, run this block per match" pattern. The
  // block receives `(world, entity)`.
  //
  //   world.each([Position, Velocity]) {|w, e|
  //     var p = w.get(e, Position)
  //     var v = w.get(e, Velocity)
  //     p.x = p.x + v.x * dt
  //   }
  //
  // Closures capture local variables, NOT the enclosing class's
  // fields. If your block needs `_renderer`, `_camera`, etc.,
  // bind them to a `var` first:
  //
  //   var renderer = _renderer        // local, captured cleanly
  //   world.each([Position, Sprite]) {|w, e|
  //     w.get(e, Sprite).draw(renderer)
  //   }
  //
  // Reading `_renderer` directly inside the block surfaces null.
  each(klasses, block) {
    for (e in query(klasses)) block.call(this, e)
  }

  // Drop every entity + component. Useful between scenes /
  // levels so users don't have to walk the world themselves.
  clear() {
    _entities = {}
    _components = {}
    _nextId = 1
  }

  toString { "World(%(_entities.count) entities, %(_components.count) component types)" }
}
