import "./fp"         for FP, Pipe
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- FP static toolbox -----------------------------------------

Test.describe("FP.identity / constant / noop") {
  Test.it("identity returns its argument") {
    Expect.that(FP.identity.call(42)).toBe(42)
    Expect.that(FP.identity.call("x")).toBe("x")
  }
  Test.it("constant ignores argument") {
    var k = FP.constant(7)
    Expect.that(k.call(1)).toBe(7)
    Expect.that(k.call("x")).toBe(7)
  }
  Test.it("noop returns null") {
    Expect.that(FP.noop.call(42)).toBe(null)
  }
}

Test.describe("FP.repeat / generate") {
  Test.it("repeat builds a filled list") {
    Expect.that(FP.repeat("x", 3)).toEqual(["x", "x", "x"])
    Expect.that(FP.repeat(0, 0)).toEqual([])
  }
  Test.it("generate builds via fn(i)") {
    Expect.that(FP.generate(4, Fn.new {|i| i * i })).toEqual([0, 1, 4, 9])
  }
}

Test.describe("FP.filter / flatMap / tap") {
  Test.it("filter is an alias for where") {
    var out = FP.filter([1, 2, 3, 4], Fn.new {|n| n % 2 == 0 }).toList
    Expect.that(out).toEqual([2, 4])
  }
  Test.it("flatMap concatenates sub-sequences") {
    var out = FP.flatMap([1, 2, 3], Fn.new {|n| [n, n * 10] })
    Expect.that(out).toEqual([1, 10, 2, 20, 3, 30])
  }
  Test.it("flatMap treats non-sequence results as scalars") {
    var out = FP.flatMap([1, 2, 3], Fn.new {|n| n * 2 })
    Expect.that(out).toEqual([2, 4, 6])
  }
  Test.it("tap runs side-effects and preserves the list") {
    var seen = []
    var out = FP.tap([1, 2, 3], Fn.new {|x| seen.add(x) })
    Expect.that(out).toEqual([1, 2, 3])
    Expect.that(seen).toEqual([1, 2, 3])
  }
}

Test.describe("FP.groupBy / partition") {
  Test.it("groupBy keys by extractor") {
    var g = FP.groupBy([1, 2, 3, 4, 5], Fn.new {|n| n % 2 })
    Expect.that(g[1]).toEqual([1, 3, 5])
    Expect.that(g[0]).toEqual([2, 4])
  }
  Test.it("partition splits into matches + rest") {
    var p = FP.partition([1, 2, 3, 4], Fn.new {|n| n > 2 })
    Expect.that(p[0]).toEqual([3, 4])
    Expect.that(p[1]).toEqual([1, 2])
  }
}

Test.describe("FP.chunked / windowed") {
  Test.it("chunked splits evenly") {
    Expect.that(FP.chunked([1, 2, 3, 4], 2)).toEqual([[1, 2], [3, 4]])
  }
  Test.it("chunked keeps a short trailing chunk") {
    Expect.that(FP.chunked([1, 2, 3, 4, 5], 2)).toEqual([[1, 2], [3, 4], [5]])
  }
  Test.it("chunked rejects size < 1") {
    var e = Fiber.new { FP.chunked([1, 2], 0) }.try()
    Expect.that(e).toContain("size must be >= 1")
  }
  Test.it("windowed with default step 1") {
    Expect.that(FP.windowed([1, 2, 3, 4], 2)).toEqual([[1, 2], [2, 3], [3, 4]])
  }
  Test.it("windowed with custom step") {
    Expect.that(FP.windowed([1, 2, 3, 4, 5], 2, 2)).toEqual([[1, 2], [3, 4]])
  }
  Test.it("windowed shorter than input returns empty") {
    Expect.that(FP.windowed([1], 2)).toEqual([])
  }
}

Test.describe("FP.zip / zipWith / unzip / withIndex") {
  Test.it("zip truncates to shorter") {
    var z = FP.zip([1, 2, 3], ["a", "b"])
    Expect.that(z).toEqual([[1, "a"], [2, "b"]])
  }
  Test.it("zipWith applies the combiner") {
    var out = FP.zipWith([1, 2, 3], [10, 20, 30], Fn.new {|a, b| a + b })
    Expect.that(out).toEqual([11, 22, 33])
  }
  Test.it("unzip inverts zip") {
    var u = FP.unzip([[1, "a"], [2, "b"], [3, "c"]])
    Expect.that(u[0]).toEqual([1, 2, 3])
    Expect.that(u[1]).toEqual(["a", "b", "c"])
  }
  Test.it("withIndex pairs each with its index") {
    Expect.that(FP.withIndex(["x", "y", "z"]))
      .toEqual([[0, "x"], [1, "y"], [2, "z"]])
  }
}

Test.describe("FP.sorted / sortedBy / sortedByDesc / sortedWith") {
  Test.it("sorted ascending on Num") {
    Expect.that(FP.sorted([3, 1, 2])).toEqual([1, 2, 3])
  }
  Test.it("sortedBy uses a key extractor") {
    var out = FP.sortedBy(["bb", "a", "ccc"], Fn.new {|s| s.count })
    Expect.that(out).toEqual(["a", "bb", "ccc"])
  }
  Test.it("sortedByDesc reverses") {
    var out = FP.sortedByDesc([1, 3, 2], Fn.new {|n| n })
    Expect.that(out).toEqual([3, 2, 1])
  }
  Test.it("sortedWith uses a custom comparator") {
    var out = FP.sortedWith([3, 1, 2], Fn.new {|a, b| a < b })
    Expect.that(out).toEqual([1, 2, 3])
  }
  Test.it("sorted does not mutate input") {
    var src = [3, 1, 2]
    FP.sorted(src)
    Expect.that(src).toEqual([3, 1, 2])
  }
}

Test.describe("FP.scan / takeWhile / dropWhile") {
  Test.it("scan returns running reductions incl. init") {
    var s = FP.scan([1, 2, 3, 4], 0, Fn.new {|acc, x| acc + x })
    Expect.that(s).toEqual([0, 1, 3, 6, 10])
  }
  Test.it("takeWhile stops at first false") {
    var out = FP.takeWhile([1, 2, 3, 0, 5], Fn.new {|n| n > 0 })
    Expect.that(out).toEqual([1, 2, 3])
  }
  Test.it("dropWhile starts at first false — doesn't re-drop") {
    var out = FP.dropWhile([1, 2, 3, 0, 5], Fn.new {|n| n > 0 })
    Expect.that(out).toEqual([0, 5])
  }
}

Test.describe("FP.distinct / distinctBy") {
  Test.it("distinct keeps first occurrence") {
    Expect.that(FP.distinct([1, 2, 2, 3, 1, 4])).toEqual([1, 2, 3, 4])
  }
  Test.it("distinctBy uses a key extractor") {
    var words = ["apple", "ant", "bee", "ball"]
    Expect.that(FP.distinctBy(words, Fn.new {|s| s[0] })).toEqual(["apple", "bee"])
  }
}

Test.describe("FP.first / last / firstWhere / lastWhere") {
  Test.it("first / last on non-empty") {
    Expect.that(FP.first([1, 2, 3])).toBe(1)
    Expect.that(FP.last([1, 2, 3])).toBe(3)
  }
  Test.it("null on empty") {
    Expect.that(FP.first([])).toBe(null)
    Expect.that(FP.last([])).toBe(null)
  }
  Test.it("firstWhere / lastWhere filter") {
    var xs = [1, 2, 3, 4]
    Expect.that(FP.firstWhere(xs, Fn.new {|n| n > 2 })).toBe(3)
    Expect.that(FP.lastWhere(xs, Fn.new {|n| n > 2 })).toBe(4)
    Expect.that(FP.firstWhere(xs, Fn.new {|n| n > 10 })).toBe(null)
  }
}

Test.describe("FP.min / max / minBy / maxBy") {
  Test.it("min / max return the extreme") {
    Expect.that(FP.min([3, 1, 4, 1, 5, 9, 2, 6])).toBe(1)
    Expect.that(FP.max([3, 1, 4, 1, 5, 9, 2, 6])).toBe(9)
  }
  Test.it("minBy / maxBy return the ELEMENT") {
    var words = ["bbb", "a", "cc"]
    Expect.that(FP.minBy(words, Fn.new {|s| s.count })).toBe("a")
    Expect.that(FP.maxBy(words, Fn.new {|s| s.count })).toBe("bbb")
  }
  Test.it("null on empty") {
    Expect.that(FP.min([])).toBe(null)
    Expect.that(FP.maxBy([], FP.identity)).toBe(null)
  }
}

Test.describe("FP.sum / sumBy") {
  Test.it("sum of numbers") {
    Expect.that(FP.sum([1, 2, 3, 4])).toBe(10)
    Expect.that(FP.sum([])).toBe(0)
  }
  Test.it("sumBy of projection") {
    var out = FP.sumBy(["aa", "b", "ccc"], Fn.new {|s| s.count })
    Expect.that(out).toBe(6)
  }
}

Test.describe("FP.concat / reversed / toMap") {
  Test.it("concat joins two lists") {
    Expect.that(FP.concat([1, 2], [3, 4])).toEqual([1, 2, 3, 4])
  }
  Test.it("concat across sequence types") {
    Expect.that(FP.concat([1, 2], 3..4)).toEqual([1, 2, 3, 4])
  }
  Test.it("reversed flips order") {
    Expect.that(FP.reversed([1, 2, 3])).toEqual([3, 2, 1])
    Expect.that(FP.reversed([])).toEqual([])
  }
  Test.it("toMap builds {key: value} from [k, v] pairs") {
    var m = FP.toMap([1, 2, 3], Fn.new {|n| [n.toString, n * n] })
    Expect.that(m["1"]).toBe(1)
    Expect.that(m["2"]).toBe(4)
    Expect.that(m["3"]).toBe(9)
  }
  Test.it("toMap: later pairs overwrite") {
    var m = FP.toMap([[1, "a"], [1, "b"]], Fn.new {|p| p })
    Expect.that(m[1]).toBe("b")
  }
}

// --- Pipe fluent wrapper ---------------------------------------

Test.describe("Pipe basics") {
  Test.it("wraps a list, toList unwraps") {
    var p = Pipe.of([1, 2, 3])
    Expect.that(p.toList).toEqual([1, 2, 3])
    Expect.that(p.unwrap is Sequence).toBe(true)
  }
  Test.it("wraps a Range") {
    Expect.that(Pipe.of(1..5).toList).toEqual([1, 2, 3, 4, 5])
  }
}

Test.describe("Pipe chains") {
  Test.it("map / where / take") {
    var out = Pipe.of(1..100)
      .where(Fn.new {|n| n % 2 == 0 })
      .map  (Fn.new {|n| n * n })
      .take (3)
      .toList
    Expect.that(out).toEqual([4, 16, 36])
  }
  Test.it("flatMap + distinct") {
    var out = Pipe.of([1, 2, 3])
      .flatMap(Fn.new {|n| [n, n] })
      .distinct
      .toList
    Expect.that(out).toEqual([1, 2, 3])
  }
  Test.it("tap inspects without changing the stream") {
    var seen = []
    var out = Pipe.of([1, 2, 3])
      .tap(Fn.new {|x| seen.add(x) })
      .map(Fn.new {|x| x + 10 })
      .toList
    Expect.that(out).toEqual([11, 12, 13])
    Expect.that(seen).toEqual([1, 2, 3])
  }
  Test.it("sortedBy + reversed + take") {
    var out = Pipe.of([{"n": 3}, {"n": 1}, {"n": 2}])
      .sortedBy(Fn.new {|m| m["n"] })
      .reversed
      .take(2)
      .map(Fn.new {|m| m["n"] })
      .toList
    Expect.that(out).toEqual([3, 2])
  }
  Test.it("zip + withIndex") {
    var out = Pipe.of(["a", "b", "c"])
      .zip([10, 20, 30])
      .withIndex
      .toList
    Expect.that(out[0]).toEqual([0, ["a", 10]])
    Expect.that(out[2]).toEqual([2, ["c", 30]])
  }
  Test.it("chunked + map over chunks") {
    var out = Pipe.of([1, 2, 3, 4, 5])
      .chunked(2)
      .map(Fn.new {|c| c.count })
      .toList
    Expect.that(out).toEqual([2, 2, 1])
  }
  Test.it("concat then reduce") {
    var out = Pipe.of([1, 2])
      .concat([3, 4])
      .reduce(0, Fn.new {|a, b| a + b })
    Expect.that(out).toBe(10)
  }
  Test.it("takeWhile / dropWhile") {
    var a = Pipe.of([1, 2, 3, 0, 5]).takeWhile(Fn.new {|n| n > 0 }).toList
    var b = Pipe.of([1, 2, 3, 0, 5]).dropWhile(Fn.new {|n| n > 0 }).toList
    Expect.that(a).toEqual([1, 2, 3])
    Expect.that(b).toEqual([0, 5])
  }
}

Test.describe("Pipe terminals") {
  Test.it("sum / count / min / max") {
    var p = Pipe.of([3, 1, 4, 1, 5, 9, 2, 6])
    Expect.that(p.sum).toBe(31)
    Expect.that(p.count).toBe(8)
    Expect.that(p.min).toBe(1)
    Expect.that(p.max).toBe(9)
  }
  Test.it("groupBy / partition") {
    var g = Pipe.of([1, 2, 3, 4, 5]).groupBy(Fn.new {|n| n % 2 })
    Expect.that(g[1]).toEqual([1, 3, 5])
    var p = Pipe.of([1, 2, 3, 4]).partition(Fn.new {|n| n > 2 })
    Expect.that(p[0]).toEqual([3, 4])
  }
  Test.it("toMap") {
    var m = Pipe.of([1, 2, 3]).toMap(Fn.new {|n| [n, n * 10] })
    Expect.that(m[2]).toBe(20)
  }
  Test.it("first / last with predicate") {
    var p = Pipe.of([1, 2, 3, 4])
    Expect.that(p.first(Fn.new {|n| n > 2 })).toBe(3)
    Expect.that(p.last (Fn.new {|n| n > 2 })).toBe(4)
  }
  Test.it("minBy / maxBy") {
    var p = Pipe.of(["bbb", "a", "cc"])
    Expect.that(p.minBy(Fn.new {|s| s.count })).toBe("a")
    Expect.that(p.maxBy(Fn.new {|s| s.count })).toBe("bbb")
  }
}

Test.run()
