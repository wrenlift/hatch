import "./color"       for Color
import "@hatch:math"   for Vec4
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("Color constructors") {
  Test.it("new / rgb / rgba") {
    var a = Color.new(0.1, 0.2, 0.3, 0.4)
    Expect.that(a.r).toBe(0.1)
    Expect.that(a.g).toBe(0.2)
    Expect.that(a.b).toBe(0.3)
    Expect.that(a.a).toBe(0.4)

    var b = Color.rgb(0.5, 0.6, 0.7)
    Expect.that(b.a).toBe(1)

    var c = Color.rgba(0.1, 0.2, 0.3, 0.4)
    Expect.that(c == a).toBe(true)
  }

  Test.it("named constants") {
    Expect.that(Color.white.r).toBe(1)
    Expect.that(Color.white.a).toBe(1)
    Expect.that(Color.black.r).toBe(0)
    Expect.that(Color.transparent.a).toBe(0)
    Expect.that(Color.red.r).toBe(1)
    Expect.that(Color.red.g).toBe(0)
    Expect.that(Color.green.g).toBe(1)
    Expect.that(Color.blue.b).toBe(1)
  }
}

Test.describe("Color.hex") {
  Test.it("parses #rrggbb") {
    var c = Color.hex("#ff8000")
    Expect.that(c.approxEq(Color.new(1, 128/255, 0, 1))).toBe(true)
  }

  Test.it("parses #rrggbbaa") {
    var c = Color.hex("#22aaff80")
    Expect.that(c.approxEq(Color.new(34/255, 170/255, 1, 128/255))).toBe(true)
  }

  Test.it("parses #rgb shorthand") {
    // #f80 → r=ff, g=88, b=00 (each nibble doubled, not the digit times 17 to 255)
    var c = Color.hex("#f80")
    Expect.that(c.approxEq(Color.new(255/255, 136/255, 0, 1))).toBe(true)
  }

  Test.it("accepts no leading hash") {
    var a = Color.hex("ff8000")
    var b = Color.hex("#ff8000")
    Expect.that(a == b).toBe(true)
  }

  Test.it("case-insensitive") {
    Expect.that(Color.hex("#FFAA00") == Color.hex("#ffaa00")).toBe(true)
  }
}

Test.describe("Color.hsv") {
  Test.it("h=0 with s=1 v=1 is red") {
    var c = Color.hsv(0, 1, 1)
    Expect.that(c.approxEq(Color.new(1, 0, 0, 1))).toBe(true)
  }

  Test.it("h=1/3 with s=1 v=1 is green") {
    var c = Color.hsv(1/3, 1, 1)
    Expect.that(c.approxEq(Color.new(0, 1, 0, 1))).toBe(true)
  }

  Test.it("h=2/3 with s=1 v=1 is blue") {
    var c = Color.hsv(2/3, 1, 1)
    Expect.that(c.approxEq(Color.new(0, 0, 1, 1))).toBe(true)
  }

  Test.it("s=0 returns greyscale") {
    var c = Color.hsv(0.4, 0, 0.7)
    Expect.that(c.approxEq(Color.new(0.7, 0.7, 0.7, 1))).toBe(true)
  }

  Test.it("hue wraps cyclically") {
    var a = Color.hsv(0.1, 1, 1)
    var b = Color.hsv(1.1, 1, 1)
    Expect.that(a.approxEq(b)).toBe(true)
  }
}

Test.describe("Color.lerp") {
  Test.it("endpoints") {
    var a = Color.new(0, 0, 0, 0)
    var b = Color.new(1, 1, 1, 1)
    Expect.that(Color.lerp(a, b, 0) == a).toBe(true)
    Expect.that(Color.lerp(a, b, 1) == b).toBe(true)
  }

  Test.it("midpoint") {
    var a = Color.new(0, 0.5, 1, 0)
    var b = Color.new(1, 0.5, 0, 1)
    var m = Color.lerp(a, b, 0.5)
    Expect.that(m.approxEq(Color.new(0.5, 0.5, 0.5, 0.5))).toBe(true)
  }
}

Test.describe("Color operations") {
  Test.it("scale touches RGB only") {
    var c = Color.new(0.4, 0.5, 0.6, 0.8)
    var s = c.scale(0.5)
    Expect.that(s.approxEq(Color.new(0.2, 0.25, 0.3, 0.8))).toBe(true)
  }

  Test.it("withAlpha") {
    var c = Color.new(0.1, 0.2, 0.3, 1)
    Expect.that(c.withAlpha(0.5).a).toBe(0.5)
    Expect.that(c.withAlpha(0.5).r).toBe(0.1)
  }

  Test.it("toVec4 round-trip") {
    var c = Color.new(0.1, 0.2, 0.3, 0.4)
    var v = c.toVec4
    Expect.that(v is Vec4).toBe(true)
    Expect.that(v.x).toBe(0.1)
    Expect.that(v.w).toBe(0.4)
  }
}

Test.run()
