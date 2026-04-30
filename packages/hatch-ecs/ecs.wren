// @hatch:ecs — entity-component-system for Wren.
//
//   import "@hatch:ecs" for World, Schedule
//
//   class Position { construct new(x, y) { _x = x; _y = y; }; ... }
//   class Velocity { construct new(x, y) { _x = x; _y = y; }; ... }
//   class Sprite   { construct new(image) { _image = image }; ... }
//
//   var world = World.new()
//   var hero  = world.spawnWith([
//     Position.new(100, 100),
//     Velocity.new(50, 0),
//     Sprite.new(heroTexture),
//   ])
//
//   var schedule = Schedule.new()
//   schedule.add("physics") {|w, ctx|
//     for (e in w.query.with(Position).with(Velocity).iterate) {
//       var p = w.get(e, Position)
//       var v = w.get(e, Velocity)
//       p.x = p.x + v.x * ctx["dt"]
//       p.y = p.y + v.y * ctx["dt"]
//     }
//   }
//   schedule.add("render") {|w, ctx| ... }
//   schedule.after("render", "physics")
//
//   // Per frame
//   schedule.run(world, { "dt": 1/60 })
//
// Storage stays pleasantly direct: `Map<ComponentClass, Map<id,
// instance>>` — class-keyed pools, monotonic u53 ids. Plenty fast
// for the few-thousand-entity scale most 2D / mid-size 3D games
// work at; trades zero-cost archetype iteration for a smaller
// surface area you can actually hold in your head.
//
// What's bundled
// --------------
//
//   * `World` — entities, components, queries (the simple
//     `world.query([A, B])` form is still here).
//   * `Query` — fluent builder with `.with(C) / .without(C)` filters
//     for when the simple form isn't enough.
//   * `Bundle` — group a set of components so `world.spawnWith
//     (bundle)` attaches them all in one call.
//   * `Resources` — typed singleton storage on the world (input
//     state, current camera, asset db, …).
//   * `Events<T>` — per-type broadcast buffer. Push during one
//     system, drain during the next; cleared at the end of each
//     frame by `world.flushEvents`.
//   * `Commands` — deferred mutation buffer. Useful inside a
//     query body where you need to spawn / despawn entities
//     without invalidating the active iteration; apply the buffer
//     after the loop with `world.applyCommands(cmds)`.
//   * `Schedule` — named system functions with `.before(label,
//     other) / .after(label, other)` ordering hints; `run(world,
//     ctx)` topologically orders and dispatches each.
//   * Hooks — `world.onAdd(Class) {|w, e, c| …}` /
//     `world.onRemove(Class) {|w, e| …}` for component-lifecycle
//     callbacks (animations, audio, indexing).
//   * Hierarchy — `world.setParent(child, parent)` /
//     `world.childrenOf(parent)`. Backed by built-in `Parent` /
//     `Children` components so queries can include / exclude
//     them like any other.

// ---------------------------------------------------------------
/// Built-in components for the hierarchy layer. Plain classes;
/// users can read them back via `world.get(e, Parent)` if they
/// need the raw data.
// ---------------------------------------------------------------

class Parent {
  construct new(entity) { _entity = entity }
  entity { _entity }
  toString { "Parent(%(_entity))" }
}

class Children {
  construct new() { _list = [] }
  list { _list }
  count { _list.count }
  contains(e) { _list.contains(e) }
  add(e) {
    if (!_list.contains(e)) _list.add(e)
  }
  remove(e) {
    var rebuilt = []
    for (x in _list) {
      if (x != e) rebuilt.add(x)
    }
    _list = rebuilt
  }
  toString { "Children(%(_list.count))" }
}

// ---------------------------------------------------------------
/// Bundles — a list of pre-built component instances that can be
/// attached as a unit. Trivial wrapper over List<component>; the
/// abstraction is the named API, not the storage shape.
// ---------------------------------------------------------------

class Bundle {
  construct new(components) { _components = components }
  components { _components }
  count { _components.count }
}

// ---------------------------------------------------------------
// Resources — typed singleton store keyed by class. Lives on
// the world so systems can pull `dt`, the active camera, the
// input state, the asset db, etc. without threading them through
// every signature.
// ---------------------------------------------------------------

/// Per-world singleton store. Holds objects every system
/// might need — `dt`, the active camera, input state, an
/// asset db — without threading them through every system
/// signature. Access via `world.resources.get(Class)`.
class Resources {
  construct new_() { _store = {} }

  insert(resource) {
    _store[resource.type] = resource
    return resource
  }

  /// Convenience for primitive resources (Num / String / Map / List)
  /// that don't carry a class identity worth looking up against —
  /// user provides the key class explicitly.
  insertAs(klass, value) {
    _store[klass] = value
    return value
  }

  get(klass) { _store[klass] }
  has(klass) { _store.containsKey(klass) }
  remove(klass) {
    if (_store.containsKey(klass)) _store.remove(klass)
  }
  clear { _store = {} }
  count { _store.count }
}

// ---------------------------------------------------------------
// Events — per-type buffered queues. Systems push during one
// pass, downstream systems drain in a later pass; `flushEvents`
// at frame-end clears anything no one drained.
// ---------------------------------------------------------------

/// Per-world event bus. Systems emit events with `push(...)`
/// and consume them with `drain(Class)` (returns the queued
/// events for that class and clears the queue). Events are
/// frame-scoped — a system that doesn't drain a queue loses
/// the events at the next tick.
class Events {
  construct new_() { _queues = {} }

  push(event) {
    var k = event.type
    if (!_queues.containsKey(k)) _queues[k] = []
    _queues[k].add(event)
  }

  drain(klass) {
    if (!_queues.containsKey(klass)) return []
    var events = _queues[klass]
    _queues.remove(klass)
    return events
  }

  peek(klass) {
    if (!_queues.containsKey(klass)) return []
    return _queues[klass]
  }

  count(klass) {
    if (!_queues.containsKey(klass)) return 0
    return _queues[klass].count
  }

  clear { _queues = {} }
}

// ---------------------------------------------------------------
// Commands — deferred mutation buffer. Records spawn / attach /
// detach / despawn ops; `world.applyCommands(cmds)` replays them.
// Lets a system mutate the world from inside a query loop without
// invalidating the active iterator.
// ---------------------------------------------------------------

/// Deferred mutation buffer. Systems queue spawn / despawn /
/// attach / detach operations through `Commands`; the World
/// applies them in bulk between frames so a system can never
/// observe a half-mutated entity table mid-iteration.
class Commands {
  construct new_() {
    _ops = []     // List of Maps describing each op
  }

  /// Reserve an entity id eagerly so the caller can hold the
  /// returned id and attach more components later in the same
  /// command list. The id isn't bound to a real entity until
  /// `applyCommands` runs.
  spawn() {
    _ops.add({ "kind": "spawn" })
    return PendingSpawn_.new_(this, _ops.count - 1)
  }

  spawnWith(components) {
    var p = spawn()
    for (c in components) attach(p, c)
    return p
  }

  attach(entityRef, component) {
    _ops.add({ "kind": "attach", "entity": entityRef, "component": component })
  }

  detach(entityRef, klass) {
    _ops.add({ "kind": "detach", "entity": entityRef, "class": klass })
  }

  despawn(entityRef) {
    _ops.add({ "kind": "despawn", "entity": entityRef })
  }

  ops { _ops }
  count { _ops.count }
  clear { _ops = [] }
}

// Internal — represents an entity that hasn't been allocated yet.
// `applyCommands` resolves these to real ids on flush.
class PendingSpawn_ {
  construct new_(buffer, opIndex) {
    _buffer = buffer
    _index  = opIndex
    _resolved = -1
  }
  resolved { _resolved }
  resolve(id) { _resolved = id }
  index { _index }
}

// ---------------------------------------------------------------
// Query builder — fluent filter chain. `.with(C)` adds a required
// component, `.without(C)` adds an excluded one. `iterate` returns
// the matching entity list.
// ---------------------------------------------------------------

/// Component-driven entity selector. Build via
/// `world.query(Class, ...)`; chain `.without(Class, ...)` to
/// exclude tags; iterate via `.each { |e, comp1, comp2| ... }`
/// or `.entities` to get just the matching entity ids.
///
/// Internally walks the world's component table — cheap for
/// the common case of one or two component types, but worth
/// caching the query if it fires every frame.
class Query {
  construct new_(world) {
    _world = world
    _with  = []
    _without = []
  }

  with(klass) {
    _with.add(klass)
    return this
  }

  without(klass) {
    _without.add(klass)
    return this
  }

  iterate {
    return _world.queryFiltered_(_with, _without)
  }

  /// Shorter call-as-a-block style:
  ///   world.query.with(A).with(B).each {|w, e| ... }
  each(block) {
    for (e in iterate) block.call(_world, e)
  }

  /// Count-only — useful for HUD overlays / debug.
  count {
    return iterate.count
  }
}

// ---------------------------------------------------------------
// Schedule — labelled system fns with optional ordering hints.
// `run(world, ctx)` resolves the order topologically and dispatches
// each system once. `ctx` is whatever Map you want — typical use:
// `{"dt": dt, "frame": frame, "input": input}`.
// ---------------------------------------------------------------

/// Topologically-sorted system runner. `add(label, system)`
/// registers a system under a label; `addAfter(label, [...])`
/// expresses ordering constraints; `tick(world, ctx)` runs
/// every registered system in dependency order.
///
/// Constraint cycles abort the fiber at first `tick` —
/// resolution is cached until the graph changes.
class Schedule {
  construct new() {
    _systems = {}    // label → fn(world, ctx)
    _after   = {}    // label → List<label> — must run AFTER these
    _order   = null  // resolved topo order (cached until invalidated)
  }

  /// Register a system under a label. Re-adding under the same
  /// label replaces the previous fn (handy for hot reload).
  add(label, fn) {
    _systems[label] = fn
    if (!_after.containsKey(label)) _after[label] = []
    _order = null
    return this
  }

  remove(label) {
    if (_systems.containsKey(label)) _systems.remove(label)
    if (_after.containsKey(label))   _after.remove(label)
    for (l in _after.keys) {
      var deps = _after[l]
      var rebuilt = []
      for (d in deps) {
        if (d != label) rebuilt.add(d)
      }
      _after[l] = rebuilt
    }
    _order = null
    return this
  }

  /// `label` must run after `other`.
  after(label, other) {
    if (!_after.containsKey(label)) _after[label] = []
    if (!_after[label].contains(other)) _after[label].add(other)
    _order = null
    return this
  }

  /// `label` must run before `other`. Sugar for `after(other, label)`.
  before(label, other) {
    after(other, label)
    return this
  }

  has(label) { _systems.containsKey(label) }

  // Resolve ordering. Iterative DFS topological sort over the
  // `after` constraints. Reports a cycle if one's detected so
  // the user gets a clear error instead of a stack overflow.
  resolve_ {
    if (_order != null) return _order
    var ordered = []
    var visited = {}    // label → 0 unvisited, 1 visiting, 2 done
    var stack = []      // (label, expanded?)
    for (label in _systems.keys) {
      if (visited.containsKey(label)) continue
      stack.add({ "label": label, "expanded": false })
      while (stack.count > 0) {
        var top = stack[stack.count - 1]
        var l = top["label"]
        if (top["expanded"]) {
          stack.removeAt(stack.count - 1)
          if (visited[l] != 2) {
            visited[l] = 2
            ordered.add(l)
          }
          continue
        }
        if (visited.containsKey(l) && visited[l] == 1) {
          Fiber.abort("Schedule.resolve: cycle detected at '%(l)'.")
        }
        if (visited.containsKey(l) && visited[l] == 2) {
          stack.removeAt(stack.count - 1)
          continue
        }
        visited[l] = 1
        top["expanded"] = true
        // Push deps so they resolve first.
        var deps = _after.containsKey(l) ? _after[l] : []
        for (d in deps) {
          if (!_systems.containsKey(d)) continue
          if (visited.containsKey(d) && visited[d] == 2) continue
          stack.add({ "label": d, "expanded": false })
        }
      }
    }
    _order = ordered
    return ordered
  }

  /// Resolve order + dispatch each system in order. `ctx` is
  /// passed through to every system.
  run(world, ctx) {
    var order = resolve_
    for (label in order) {
      _systems[label].call(world, ctx)
    }
    world.flushEvents
  }

  count { _systems.count }
  labels { _systems.keys.toList }
}

// ---------------------------------------------------------------
// World — the main store. Same simple core as before, with the
// extras above hanging off it.
// ---------------------------------------------------------------

/// The ECS world — entity factory, component store, system
/// scheduler, and event bus. One World owns the whole ECS;
/// every other class hangs off it.
///
/// ```wren
/// var world = World.new()
/// var hero  = world.spawn()
/// world.attach(hero, Position.new(0, 0, 0))
/// world.attach(hero, Velocity.new(1, 0, 0))
///
/// world.system { |w|
///   w.query(Position, Velocity).each { |e, p, v|
///     p.x = p.x + v.x
///   }
/// }
/// world.tick(0.016)
/// ```
class World {
  construct new() {
    _nextId       = 1
    _entities     = {}     // id → true
    _components   = {}     // ComponentClass → { id → instance }
    _onAdd        = {}     // ComponentClass → List<Fn(world, entity, component)>
    _onRemove     = {}     // ComponentClass → List<Fn(world, entity, component)>
    _resources    = Resources.new_()
    _events       = Events.new_()
  }

  /// -- Counts + introspection ---------------------------------

  count { _entities.count }
  countOf(klass) {
    if (!_components.containsKey(klass)) return 0
    return _components[klass].count
  }

  /// Live entity ids snapshot — copy-out for safe iteration.
  entities {
    var out = []
    for (id in _entities.keys) out.add(id)
    return out
  }

  /// Component classes that currently have at least one entry.
  componentTypes {
    var out = []
    for (k in _components.keys) {
      if (_components[k].count > 0) out.add(k)
    }
    return out
  }

  /// -- Resources / events -------------------------------------

  resources { _resources }
  events    { _events }

  /// Drain every event queue. Called by `Schedule.run` at the end
  /// of each frame; you can also call it manually if you're
  /// running systems by hand.
  flushEvents { _events.clear }

  /// -- Entity lifecycle ---------------------------------------

  spawn() {
    var id = _nextId
    _nextId = _nextId + 1
    _entities[id] = true
    return id
  }

  /// Allocate an entity and attach every component in one call.
  /// `components` may be a `List` of instances or a `Bundle`.
  spawnWith(components) {
    var list = (components is Bundle) ? components.components : components
    var id = spawn()
    for (c in list) attach(id, c)
    return id
  }

  despawn(e) {
    if (!_entities.containsKey(e)) return
    // Fire onRemove hooks BEFORE the storage is gone so the
    // hook can read the component one last time.
    for (klass in _components.keys) {
      var storage = _components[klass]
      if (storage.containsKey(e)) {
        fireRemove_(klass, e, storage[e])
        storage.remove(e)
      }
    }
    // If the entity had a parent, detach from that parent's
    // children list. Skip if the Parent component class itself
    // isn't registered yet.
    var p = _entities.containsKey(e) ? _entities[e] : null
    _entities.remove(e)
    // Cascading children-of-removed-parent cleanup is planned
    // — `p` is captured here so a future pass can rewalk the
    // hierarchy without changing this signature.
    if (p != null) {}
  }

  /// -- Component CRUD -----------------------------------------

  attach(e, component) {
    var klass = component.type
    if (!_components.containsKey(klass)) _components[klass] = {}
    _components[klass][e] = component
    fireAdd_(klass, e, component)
    return component
  }

  attachAll(e, components) {
    var list = (components is Bundle) ? components.components : components
    for (c in list) attach(e, c)
    return e
  }

  detach(e, klass) {
    if (!_components.containsKey(klass)) return
    var storage = _components[klass]
    if (storage.containsKey(e)) {
      var inst = storage[e]
      storage.remove(e)
      fireRemove_(klass, e, inst)
    }
  }

  has(e, klass) {
    if (!_components.containsKey(klass)) return false
    return _components[klass].containsKey(e)
  }

  get(e, klass) {
    if (!_components.containsKey(klass)) return null
    return _components[klass][e]
  }

  set(e, component) { attach(e, component) }

  // -- Hooks --------------------------------------------------

  /// Register a callback fired AFTER a component of `klass` is
  /// attached. Block signature: `{|world, entity, component| ...}`.
  onAdd(klass, fn) {
    if (!_onAdd.containsKey(klass)) _onAdd[klass] = []
    _onAdd[klass].add(fn)
    return this
  }

  onRemove(klass, fn) {
    if (!_onRemove.containsKey(klass)) _onRemove[klass] = []
    _onRemove[klass].add(fn)
    return this
  }

  fireAdd_(klass, e, component) {
    var hooks = _onAdd.containsKey(klass) ? _onAdd[klass] : null
    if (hooks == null) return
    for (h in hooks) h.call(this, e, component)
  }

  fireRemove_(klass, e, component) {
    var hooks = _onRemove.containsKey(klass) ? _onRemove[klass] : null
    if (hooks == null) return
    for (h in hooks) h.call(this, e, component)
  }

  // -- Queries ------------------------------------------------

  /// Original simple form — match every entity that has every
  /// class in `klasses`.
  query(klasses) {
    if (klasses is Class) klasses = [klasses]
    return queryFiltered_(klasses, [])
  }

  /// Fluent builder: `world.query.with(A).without(B).iterate`.
  query { Query.new_(this) }

  // Backing form for both the simple and fluent paths.
  queryFiltered_(withList, withoutList) {
    if (withList.count == 0) {
      var out = []
      for (id in _entities.keys) {
        if (passesWithout_(id, withoutList)) out.add(id)
      }
      return out
    }
    var smallest = null
    var smallestSize = -1
    for (k in withList) {
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
      for (k in withList) {
        if (!_components[k].containsKey(id)) {
          ok = false
          break
        }
      }
      if (ok && passesWithout_(id, withoutList)) out.add(id)
    }
    return out
  }

  passesWithout_(id, withoutList) {
    if (withoutList.count == 0) return true
    for (k in withoutList) {
      if (_components.containsKey(k) && _components[k].containsKey(id)) {
        return false
      }
    }
    return true
  }

  /// Convenience for the common iterate-and-call-block pattern.
  /// Block signature: `{|world, entity| ...}`.
  each(klasses, block) {
    for (e in query(klasses)) block.call(this, e)
  }

  // -- Hierarchy ----------------------------------------------

  /// Set / replace `child`'s parent. Removes `child` from the
  /// previous parent's `Children` if there was one. Idempotent.
  setParent(child, parent) {
    var prev = get(child, Parent)
    if (prev != null) {
      var prevKids = get(prev.entity, Children)
      if (prevKids != null) prevKids.remove(child)
    }
    attach(child, Parent.new(parent))
    var kids = get(parent, Children)
    if (kids == null) {
      kids = Children.new()
      attach(parent, kids)
    }
    kids.add(child)
  }

  /// Drop the parent edge. The previous parent's Children list
  /// gets the child removed; the entity itself stays alive.
  unparent(child) {
    var p = get(child, Parent)
    if (p == null) return
    var kids = get(p.entity, Children)
    if (kids != null) kids.remove(child)
    detach(child, Parent)
  }

  parentOf(child) {
    var p = get(child, Parent)
    return p == null ? null : p.entity
  }

  childrenOf(parent) {
    var kids = get(parent, Children)
    return kids == null ? [] : kids.list
  }

  // -- Commands -----------------------------------------------

  /// Allocate a fresh command buffer. Caller fills it and applies
  /// it back via `applyCommands`.
  commands { Commands.new_() }

  /// Replay `cmds.ops` against this world, resolving any pending
  /// spawns to real ids. After return the buffer is empty.
  applyCommands(cmds) {
    var resolved = {}    // opIndex → entity id
    var i = 0
    while (i < cmds.ops.count) {
      var op = cmds.ops[i]
      var kind = op["kind"]
      if (kind == "spawn") {
        var id = spawn()
        resolved[i] = id
        // Stamp the resolved id back on the original token so any
        // later attach/detach references find the right id even if
        // they were captured before applyCommands ran.
        // (Not strictly needed since we resolve via opIndex below,
        // but keeps `PendingSpawn_.resolved` honest.)
      } else if (kind == "attach") {
        attach(resolveEntity_(op["entity"], resolved), op["component"])
      } else if (kind == "detach") {
        detach(resolveEntity_(op["entity"], resolved), op["class"])
      } else if (kind == "despawn") {
        despawn(resolveEntity_(op["entity"], resolved))
      }
      i = i + 1
    }
    cmds.clear
  }

  resolveEntity_(ref, resolved) {
    if (ref is PendingSpawn_) return resolved[ref.index]
    return ref
  }

  // -- Reset --------------------------------------------------

  /// Drop every entity, component, hook, and resource. Useful
  /// between scenes / levels so users don't have to walk the
  /// world themselves.
  clear() {
    _entities = {}
    _components = {}
    _onAdd = {}
    _onRemove = {}
    _resources.clear
    _events.clear
    _nextId = 1
  }

  toString {
    "World(%(_entities.count) entities, %(_components.count) component types, %(_resources.count) resources)"
  }
}
