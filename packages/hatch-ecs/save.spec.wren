// @hatch:ecs/save — snapshot + restore round-trip. Specs use small
// inline component classes with `static save / static load` to
// exercise the contract without touching the rest of the engine.

import "./ecs"         for World, SaveSystem
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// ── Component classes for fixtures ─────────────────────────────

class Position {
  construct new(x, y) {
    _x = x
    _y = y
  }
  type { Position }
  x { _x }
  y { _y }

  static save(p) { { "x": p.x, "y": p.y } }
  static load(d) { Position.new(d["x"], d["y"]) }
}

class Player {
  construct new(score, lives) {
    _score = score
    _lives = lives
  }
  type { Player }
  score { _score }
  lives { _lives }

  static save(p) { { "score": p.score, "lives": p.lives } }
  static load(d) { Player.new(d["score"], d["lives"]) }
}

// Component without save/load — should be silently skipped.
class Renderable {
  construct new(textureId) { _textureId = textureId }
  type { Renderable }
  textureId { _textureId }
}

// ── snapshot ─────────────────────────────────────────────────

Test.describe("SaveSystem.snapshot") {
  Test.it("returns the version + entities envelope") {
    var w = World.new()
    var snap = SaveSystem.snapshot(w, [Position])
    Expect.that(snap["version"]).toBe(1)
    Expect.that(snap["entities"].count).toBe(0)
  }

  Test.it("captures opted-in components for every entity") {
    var w = World.new()
    var a = w.spawn()
    w.attach(a, Position.new(1, 2))
    w.attach(a, Player.new(100, 3))
    var b = w.spawn()
    w.attach(b, Position.new(3, 4))

    var snap = SaveSystem.snapshot(w, [Position, Player])
    Expect.that(snap["entities"].count).toBe(2)
    // First record corresponds to entity `a` (insertion order).
    var aRec = snap["entities"][0]
    Expect.that(aRec["components"]["Position"]["x"]).toBe(1)
    Expect.that(aRec["components"]["Player"]["score"]).toBe(100)
    var bRec = snap["entities"][1]
    Expect.that(bRec["components"].containsKey("Player")).toBe(false)
  }

  Test.it("silently skips entities with no matching components") {
    var w = World.new()
    var orphan = w.spawn()
    var snap = SaveSystem.snapshot(w, [Position])
    Expect.that(snap["entities"].count).toBe(0)
  }

  Test.it("silently skips component classes lacking `static save`") {
    var w = World.new()
    var e = w.spawn()
    w.attach(e, Renderable.new(42))
    w.attach(e, Position.new(5, 6))
    var snap = SaveSystem.snapshot(w, [Renderable, Position])
    // Renderable has no `static save`, so the key is missing.
    Expect.that(snap["entities"][0]["components"].containsKey("Renderable")).toBe(false)
    Expect.that(snap["entities"][0]["components"]["Position"]["x"]).toBe(5)
  }

  Test.it("rejects non-list componentClasses") {
    var w = World.new()
    Expect.that(Fn.new { SaveSystem.snapshot(w, "oops") }).toAbort()
  }
}

// ── restore ──────────────────────────────────────────────────

Test.describe("SaveSystem.restore") {
  Test.it("round-trips components onto a fresh world") {
    var src = World.new()
    var a = src.spawn()
    src.attach(a, Position.new(10, 20))
    src.attach(a, Player.new(7, 2))
    var snap = SaveSystem.snapshot(src, [Position, Player])

    var dst = World.new()
    SaveSystem.restore(dst, snap, [Position, Player])
    Expect.that(dst.entities.count).toBe(1)
    var newId = dst.entities[0]
    Expect.that(dst.get(newId, Position).x).toBe(10)
    Expect.that(dst.get(newId, Player).score).toBe(7)
  }

  Test.it("allocates fresh entity ids; original id stays in the snapshot") {
    var src = World.new()
    var ignore = src.spawn()
    var ignore2 = src.spawn()
    var a = src.spawn()
    src.attach(a, Position.new(1, 1))
    var snap = SaveSystem.snapshot(src, [Position])

    var dst = World.new()
    SaveSystem.restore(dst, snap, [Position])
    var restoredId = dst.entities[0]
    // The snapshot records the original id…
    Expect.that(snap["entities"][0]["id"]).toBe(a)
    // …but the dst world started fresh and allocated id 0.
    Expect.that(restoredId == a).toBe(false)
  }

  Test.it("onEntity callback fires per-entity with (oldId, newId, components)") {
    var src = World.new()
    var a = src.spawn()
    src.attach(a, Position.new(1, 2))
    var b = src.spawn()
    src.attach(b, Position.new(3, 4))
    var snap = SaveSystem.snapshot(src, [Position])

    var calls = []
    var dst = World.new()
    SaveSystem.restore(dst, snap, [Position], { "onEntity": Fn.new {|oldId, newId, comps|
      calls.add([oldId, newId, comps["Position"]["x"]])
    }})
    Expect.that(calls.count).toBe(2)
    Expect.that(calls[0][2]).toBe(1)
    Expect.that(calls[1][2]).toBe(3)
  }

  Test.it("rejects non-Map snapshots") {
    var w = World.new()
    Expect.that(Fn.new { SaveSystem.restore(w, [], [Position]) }).toAbort()
  }

  Test.it("rejects snapshots missing the entities key") {
    var w = World.new()
    Expect.that(Fn.new { SaveSystem.restore(w, { "version": 1 }, [Position]) }).toAbort()
  }

  Test.it("silently skips component classes lacking `static load`") {
    // Snapshot was made with the class missing — restore shouldn't
    // crash on the unknown key.
    var w = World.new()
    SaveSystem.restore(w, { "version": 1, "entities": [
      { "id": 1, "components": { "Unknown": { "x": 1 }, "Position": { "x": 2, "y": 3 } } }
    ]}, [Position])
    Expect.that(w.entities.count).toBe(1)
    var e = w.entities[0]
    Expect.that(w.has(e, Position)).toBe(true)
  }
}

// ── clear ────────────────────────────────────────────────────

Test.describe("SaveSystem.clear") {
  Test.it("despawns every entity in the world") {
    var w = World.new()
    var a = w.spawn()
    var b = w.spawn()
    var c = w.spawn()
    w.attach(a, Position.new(1, 1))
    Expect.that(w.entities.count).toBe(3)

    SaveSystem.clear(w)
    Expect.that(w.entities.count).toBe(0)
  }
}

// ── End-to-end ───────────────────────────────────────────────

Test.describe("Save/load round trip") {
  Test.it("a typical scene snapshots, clears, restores cleanly") {
    var w = World.new()
    var hero = w.spawn()
    w.attach(hero, Position.new(100, 200))
    w.attach(hero, Player.new(500, 3))
    var pickup = w.spawn()
    w.attach(pickup, Position.new(50, 75))

    var snap = SaveSystem.snapshot(w, [Position, Player])
    SaveSystem.clear(w)
    Expect.that(w.entities.count).toBe(0)

    SaveSystem.restore(w, snap, [Position, Player])
    Expect.that(w.entities.count).toBe(2)
    // Find the entity with a Player (hero) and assert its fields.
    var found = false
    for (e in w.entities) {
      if (w.has(e, Player)) {
        Expect.that(w.get(e, Player).score).toBe(500)
        Expect.that(w.get(e, Position).x).toBe(100)
        found = true
      }
    }
    Expect.that(found).toBe(true)
  }
}

Test.run()
