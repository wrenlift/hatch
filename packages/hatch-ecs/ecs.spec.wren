// @hatch:ecs acceptance tests.

import "./ecs"          for World
import "@hatch:test"    for Test
import "@hatch:assert"  for Expect

class Position {
  construct new(x, y) {
    _x = x
    _y = y
  }
  x { _x }
  x=(v) { _x = v }
  y { _y }
  y=(v) { _y = v }
}

class Velocity {
  construct new(x, y) {
    _x = x
    _y = y
  }
  x { _x }
  y { _y }
}

class Tag {
  construct new(name) { _name = name }
  name { _name }
}

Test.describe("World basics") {
  Test.it("spawns ids that increment monotonically") {
    var w = World.new()
    var a = w.spawn()
    var b = w.spawn()
    Expect.that(a).toBe(1)
    Expect.that(b).toBe(2)
    Expect.that(w.count).toBe(2)
  }

  Test.it("attach + has + get round-trip") {
    var w = World.new()
    var e = w.spawn()
    var p = Position.new(10, 20)
    w.attach(e, p)
    Expect.that(w.has(e, Position)).toBe(true)
    Expect.that(w.has(e, Velocity)).toBe(false)
    Expect.that(w.get(e, Position).x).toBe(10)
    Expect.that(w.get(e, Position)).toBe(p)
  }

  Test.it("get on missing component returns null") {
    var w = World.new()
    var e = w.spawn()
    Expect.that(w.get(e, Position)).toBeNull()
  }

  Test.it("detach drops the component") {
    var w = World.new()
    var e = w.spawn()
    w.attach(e, Position.new(0, 0))
    w.detach(e, Position)
    Expect.that(w.has(e, Position)).toBe(false)
    Expect.that(w.get(e, Position)).toBeNull()
  }

  Test.it("despawn drops every component for that entity") {
    var w = World.new()
    var e = w.spawn()
    w.attach(e, Position.new(0, 0))
    w.attach(e, Velocity.new(1, 1))
    w.despawn(e)
    Expect.that(w.count).toBe(0)
    Expect.that(w.has(e, Position)).toBe(false)
    Expect.that(w.has(e, Velocity)).toBe(false)
  }

  Test.it("countOf reports per-class storage size") {
    var w = World.new()
    var e1 = w.spawn()
    var e2 = w.spawn()
    w.attach(e1, Position.new(0, 0))
    w.attach(e2, Position.new(0, 0))
    w.attach(e2, Velocity.new(1, 1))
    Expect.that(w.countOf(Position)).toBe(2)
    Expect.that(w.countOf(Velocity)).toBe(1)
    Expect.that(w.countOf(Tag)).toBe(0)
  }
}

Test.describe("World queries") {
  Test.it("empty query returns every entity") {
    var w = World.new()
    var a = w.spawn()
    var b = w.spawn()
    var got = w.query([])
    Expect.that(got.count).toBe(2)
    Expect.that(got.contains(a)).toBe(true)
    Expect.that(got.contains(b)).toBe(true)
  }

  Test.it("single-class query reads the storage directly") {
    var w = World.new()
    var a = w.spawn()
    var b = w.spawn()
    w.attach(a, Position.new(0, 0))
    var got = w.query([Position])
    Expect.that(got.count).toBe(1)
    Expect.that(got[0]).toBe(a)
  }

  Test.it("multi-class query intersects every storage") {
    var w = World.new()
    var moving = w.spawn()
    var still  = w.spawn()
    var ghost  = w.spawn()
    w.attach(moving, Position.new(0, 0))
    w.attach(moving, Velocity.new(1, 0))
    w.attach(still,  Position.new(0, 0))
    w.attach(ghost,  Velocity.new(2, 0))
    var got = w.query([Position, Velocity])
    Expect.that(got.count).toBe(1)
    Expect.that(got[0]).toBe(moving)
  }

  Test.it("returns an empty list when any required class is empty") {
    var w = World.new()
    var e = w.spawn()
    w.attach(e, Position.new(0, 0))
    Expect.that(w.query([Position, Velocity])).toEqual([])
  }

  Test.it("each(klasses, block) drives a per-entity loop") {
    var w = World.new()
    var a = w.spawn()
    var b = w.spawn()
    w.attach(a, Position.new(10, 0))
    w.attach(a, Velocity.new(5, 0))
    w.attach(b, Position.new(0, 0))
    w.attach(b, Velocity.new(2, 0))

    // Apply velocity for one tick.
    w.each([Position, Velocity]) {|world, e|
      var p = world.get(e, Position)
      var v = world.get(e, Velocity)
      p.x = p.x + v.x
    }
    Expect.that(w.get(a, Position).x).toBe(15)
    Expect.that(w.get(b, Position).x).toBe(2)
  }
}

Test.describe("World.clear") {
  Test.it("drops every entity + component and resets ids") {
    var w = World.new()
    w.attach(w.spawn(), Position.new(0, 0))
    w.attach(w.spawn(), Velocity.new(1, 0))
    Expect.that(w.count).toBe(2)
    w.clear()
    Expect.that(w.count).toBe(0)
    var fresh = w.spawn()
    Expect.that(fresh).toBe(1)
  }
}

Test.run()
