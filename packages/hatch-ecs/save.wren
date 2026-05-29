//! `@hatch:ecs/save` — ECS state snapshot + restore.
//!
//! Captures every entity's component instances against a list of
//! opted-in component classes, returning a plain Map ready for
//! `JSON.encode`. Restore spawns fresh entities and reattaches
//! components decoded from the same Map.
//!
//! ```wren
//! import "@hatch:ecs"  for World, SaveSystem
//! import "@hatch:json" for JSON
//!
//! // Snapshot:
//! var snapshot = SaveSystem.snapshot(world, [Transform, RigidBody, Player])
//! File.write("save.json", JSON.encode(snapshot))
//!
//! // Restore (against a fresh world or one cleared via
//! // SaveSystem.clear(world)):
//! var data = JSON.parse(File.read("save.json"))
//! SaveSystem.restore(world, data, [Transform, RigidBody, Player])
//! ```
//!
//! ## Opting a component into save/load
//!
//! Add `static save(instance)` returning a Map of primitive
//! fields (Num / String / Bool / List / Map) and a matching
//! `static load(data)` constructor. The snapshot format keys
//! components by `Class.name`, so the round trip stays stable as
//! long as the class name is.
//!
//! ```wren
//! class Player {
//!   construct new(score, lives) {
//!     _score = score
//!     _lives = lives
//!   }
//!   score { _score }
//!   lives { _lives }
//!
//!   static save(p) { { "score": p.score, "lives": p.lives } }
//!   static load(d) { Player.new(d["score"], d["lives"]) }
//! }
//! ```
//!
//! Component classes without `save` / `load` are silently skipped
//! during snapshot — only opt-in state crosses the boundary, so
//! transient runtime fields (timers, GPU handles, fiber state)
//! stay out of the save.
//!
//! ## Entity-id remapping
//!
//! Snapshot stores each entity's original id alongside its
//! components, but `restore` always allocates fresh ids — the
//! World id space is monotonic, not addressable. For component
//! data that references *other* entities by id (e.g. a
//! `Target { ownerId }` component), pass an `onEntity` callback
//! to `restore(world, data, classes, { "onEntity": fn })` so
//! the caller can build an old-id → new-id map and patch
//! cross-references in a post-pass.

/// ECS state serialiser. Stateless — every method is static.
class SaveSystem {
  /// Capture the World's component state for every class in
  /// `componentClasses` that opts in via `static save(instance)`.
  /// Returns a fresh Map of the form:
  ///
  /// ```wren
  /// {
  ///   "version": 1,
  ///   "entities": [
  ///     { "id": 1, "components": { "Transform": {...}, "Player": {...} } },
  ///     { "id": 2, "components": { "Transform": {...} } },
  ///     ...
  ///   ]
  /// }
  /// ```
  ///
  /// Entities with zero matching components are dropped from
  /// the output so an empty save (no opted-in classes) produces
  /// `{ "version": 1, "entities": [] }`.
  ///
  /// @param  {World}        world
  /// @param  {List<Class>}  componentClasses
  /// @returns {Map}
  static snapshot(world, componentClasses) {
    if (!(componentClasses is List)) {
      Fiber.abort("SaveSystem.snapshot: componentClasses must be a List<Class>")
    }
    var entities = []
    var ids = world.entities
    var i = 0
    while (i < ids.count) {
      var e = ids[i]
      var comps = {}
      var j = 0
      while (j < componentClasses.count) {
        var klass = componentClasses[j]
        if (world.has(e, klass)) {
          // Skip classes that don't opt in. Wren has no
          // `.respond?(_)` so we treat absence of the method as
          // a runtime abort the caller catches.
          var inst = world.get(e, klass)
          var serialized = SaveSystem.serialise_(klass, inst)
          if (serialized != null) comps[klass.name] = serialized
        }
        j = j + 1
      }
      if (comps.count > 0) {
        entities.add({ "id": e, "components": comps })
      }
      i = i + 1
    }
    return { "version": 1, "entities": entities }
  }

  // Call `klass.save(inst)` inside a Fiber so a class that
  // doesn't implement the static method returns `null` cleanly
  // instead of aborting the whole snapshot. Wren has no
  // reflective `respond?`; this is the cheapest stand-in.
  static serialise_(klass, inst) {
    var fb = Fiber.new {
      return klass.save(inst)
    }
    var result = fb.try()
    if (fb.error != null) return null
    return result
  }

  /// Restore components onto entities in `world` from a snapshot
  /// produced by `snapshot(...)`. Spawns one fresh entity per
  /// snapshot record (the original `id` field is read but not
  /// re-used — the World id space allocates monotonically).
  ///
  /// `componentClasses` is the same list passed to `snapshot`;
  /// it acts as the class-name → class lookup for restoring.
  /// Classes missing from the list silently skip their
  /// component data — same trim-on-load behaviour as snapshot.
  ///
  /// @param  {World}        world
  /// @param  {Map}          snapshot
  /// @param  {List<Class>}  componentClasses
  static restore(world, snapshot, componentClasses) {
    restore(world, snapshot, componentClasses, {})
  }

  /// As `restore(world, snapshot, classes)` with an extra
  /// options Map. Recognised keys:
  ///
  /// | Key | Type | Notes |
  /// |---|---|---|
  /// | `onEntity` | `Fn(oldId, newId, components)` | Fired after each entity is restored. Build a cross-reference map here when components reference other entities by id. |
  ///
  /// @param  {World}        world
  /// @param  {Map}          snapshot
  /// @param  {List<Class>}  componentClasses
  /// @param  {Map}          options
  static restore(world, snapshot, componentClasses, options) {
    if (!(snapshot is Map))                  Fiber.abort("SaveSystem.restore: snapshot must be a Map")
    if (!snapshot.containsKey("entities"))   Fiber.abort("SaveSystem.restore: snapshot missing 'entities' key")
    if (!(componentClasses is List))         Fiber.abort("SaveSystem.restore: componentClasses must be a List<Class>")
    var onEntity = options.containsKey("onEntity") ? options["onEntity"] : null

    var byName = {}
    var i = 0
    while (i < componentClasses.count) {
      byName[componentClasses[i].name] = componentClasses[i]
      i = i + 1
    }

    var entities = snapshot["entities"]
    var j = 0
    while (j < entities.count) {
      var record = entities[j]
      var oldId = record["id"]
      var newId = world.spawn()
      var comps = record["components"]
      for (entry in comps) {
        var klass = byName[entry.key]
        if (klass != null) {
          var inst = SaveSystem.deserialise_(klass, entry.value)
          if (inst != null) world.attach(newId, inst)
        }
      }
      if (onEntity != null) onEntity.call(oldId, newId, comps)
      j = j + 1
    }
  }

  // Mirror of `serialise_`. Calls `klass.load(data)` inside a
  // Fiber and falls back to `null` on any abort so a botched
  // single component doesn't take down the whole restore pass.
  static deserialise_(klass, data) {
    var fb = Fiber.new {
      return klass.load(data)
    }
    var result = fb.try()
    if (fb.error != null) return null
    return result
  }

  /// Despawn every entity in `world`. Useful as a one-call
  /// reset before `restore` populates fresh state. Lifecycle
  /// hooks (`onRemove`) fire as normal during the despawn pass.
  ///
  /// @param {World} world
  static clear(world) {
    var ids = world.entities
    var i = 0
    while (i < ids.count) {
      world.despawn(ids[i])
      i = i + 1
    }
  }
}
