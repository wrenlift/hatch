/// `@hatch:fp`: fluent and functional collection operations.
///
/// ```wren
/// import "@hatch:fp" for FP, Pipe
///
/// // Static toolbox. Each takes a sequence and a lambda:
/// FP.flatMap([[1, 2], [3]], Fn.new {|xs| xs })      //= [1, 2, 3]
/// FP.groupBy([1, 2, 3, 4], Fn.new {|n| n % 2 })     //= { 1: [1, 3], 0: [2, 4] }
/// FP.partition([1, 2, 3, 4], Fn.new {|n| n > 2 })   //= [[3, 4], [1, 2]]
/// FP.zipWith([1, 2, 3], [10, 20, 30], Fn.new {|a, b| a + b })  //= [11, 22, 33]
/// FP.sortedBy(["bb", "a", "ccc"], Fn.new {|s| s.count })       //= ["a", "bb", "ccc"]
/// FP.chunked([1, 2, 3, 4, 5], 2)                    //= [[1, 2], [3, 4], [5]]
///
/// // Fluent pipeline. Chains compose left-to-right. Each op
/// // eagerly materialises into a List, so long chains are still
/// // O(n) per step. Terminates with `.toList`, `.reduce`, etc.
/// Pipe.of(1..10)
///   .where(Fn.new {|n| n % 2 == 0 })
///   .map  (Fn.new {|n| n * n })
///   .take (3)
///   .toList                                          //= [4, 16, 36]
/// ```
///
/// Wren's stock `Sequence` already does `map` / `where` / `take`
/// / `skip` / `reduce` / `each` / `count` / `any` / `all` /
/// `contains` / `join` / `toList`. `@hatch:fp` layers the rest
/// on top: `flatMap`, `groupBy`, `partition`, `zip` / `zipWith`,
/// `sortedBy`, `chunked`, `windowed`, `scan`, `tap`,
/// `takeWhile` / `dropWhile`, `distinct`, `first` / `last` /
/// `min` / `max`, `sum`, `concat`, `reversed`, `withIndex`,
/// `toMap`.
///
/// Everything here is pure Wren, with no runtime module, so the
/// JIT tier-ups it like any hot user code.

class FP {
  // -- Identity / constant / no-op ---------------------------------------

  /// A no-op function that returns its argument unchanged. Useful
  /// as a default where a key-extractor is expected.
  ///
  /// ```wren
  /// FP.distinctBy([1, 2, 2, 3], FP.identity)  //= [1, 2, 3]
  /// ```
  static identity { Fn.new {|x| x } }

  /// Returns a function that ignores its argument and always yields
  /// `value`. Handy for `.map(FP.constant(0))` to zero out a list.
  static constant(value) { Fn.new {|_| value } }

  /// Returns an empty function. Takes one arg, returns null. The
  /// sensible default for `.tap` when only a debug print is wanted.
  static noop { Fn.new {|_| null } }

  // -- Constructors ------------------------------------------------------

  /// Build a list of `value` repeated `n` times. Equivalent to
  /// `List.filled(n, value)` but reads naturally alongside other
  /// FP constructors.
  static repeat(value, n) { List.filled(n, value) }

  /// Build a list by applying `fn(i)` for `i` in `0...n`.
  ///
  /// ```wren
  /// FP.generate(5, Fn.new {|i| i * i })    //= [0, 1, 4, 9, 16]
  /// ```
  static generate(n, fn) {
    var out = []
    var i = 0
    while (i < n) {
      out.add(fn.call(i))
      i = i + 1
    }
    return out
  }

  // -- Basic transforms --------------------------------------------------

  /// Alias for `seq.where(fn)`. Reads better in some chains.
  static filter(seq, fn) { seq.where(fn) }

  /// Each element produces a sub-sequence; flatten one level.
  ///
  /// ```wren
  /// FP.flatMap([[1, 2], [3], [4, 5]], Fn.new {|xs| xs })
  /// //= [1, 2, 3, 4, 5]
  /// ```
  ///
  /// `fn` may return any `Sequence` (`List`, `Range`, `String`,
  /// another wrapper). Each result is iterated and concatenated.
  static flatMap(seq, fn) {
    var out = []
    for (x in seq) {
      var sub = fn.call(x)
      if (sub is Sequence) {
        for (y in sub) out.add(y)
      } else {
        // Non-sequence result: treated as a single element. Lets
        // callers write simple `fn` bodies that sometimes return
        // the scalar directly without wrapping in a list.
        out.add(sub)
      }
    }
    return out
  }

  /// Run `fn` on each element for its side effect; return the list
  /// of the same elements unchanged. Chain-friendly.
  ///
  /// ```wren
  /// Pipe.of([1, 2, 3])
  ///   .tap (Fn.new {|x| System.print(x) })
  ///   .map (Fn.new {|x| x * 2 })
  ///   .toList
  /// ```
  static tap(seq, fn) {
    var out = []
    for (x in seq) {
      fn.call(x)
      out.add(x)
    }
    return out
  }

  // -- Grouping / splitting ----------------------------------------------

  /// Bucket elements by `keyFn(element)`. Returns a `Map` from key
  /// to a `List` of elements with that key. Preserves per-bucket
  /// insertion order.
  ///
  /// ```wren
  /// FP.groupBy(["apple", "ant", "bee"], Fn.new {|s| s[0] })
  /// //= { "a": ["apple", "ant"], "b": ["bee"] }
  /// ```
  static groupBy(seq, keyFn) {
    var out = {}
    for (x in seq) {
      var k = keyFn.call(x)
      if (!out.containsKey(k)) out[k] = []
      out[k].add(x)
    }
    return out
  }

  /// Split into `[matches, rest]` using a boolean predicate. Single
  /// pass, preserves order within each side.
  ///
  /// ```wren
  /// FP.partition([1, 2, 3, 4], Fn.new {|n| n > 2 })
  /// //= [[3, 4], [1, 2]]
  /// ```
  static partition(seq, pred) {
    var yes = []
    var no = []
    for (x in seq) {
      if (pred.call(x)) yes.add(x) else no.add(x)
    }
    return [yes, no]
  }

  /// Break into fixed-size chunks. The last chunk may be shorter
  /// if the total isn't divisible by `n`.
  ///
  /// ```wren
  /// FP.chunked([1, 2, 3, 4, 5], 2)  //= [[1, 2], [3, 4], [5]]
  /// ```
  static chunked(seq, n) {
    if (!(n is Num) || n < 1) Fiber.abort("FP.chunked: size must be >= 1")
    var out = []
    var buf = []
    for (x in seq) {
      buf.add(x)
      if (buf.count == n) {
        out.add(buf)
        buf = []
      }
    }
    if (buf.count > 0) out.add(buf)
    return out
  }

  /// Sliding windows of length `size`, advancing by `step` each
  /// time. Defaults to a step of 1 (standard overlap-1 window).
  ///
  /// ```wren
  /// FP.windowed([1, 2, 3, 4], 2)          //= [[1,2], [2,3], [3,4]]
  /// FP.windowed([1, 2, 3, 4, 5], 2, 2)    //= [[1,2], [3,4]]
  /// ```
  static windowed(seq, size) { windowed(seq, size, 1) }
  static windowed(seq, size, step) {
    if (!(size is Num) || size < 1) Fiber.abort("FP.windowed: size must be >= 1")
    if (!(step is Num) || step < 1) Fiber.abort("FP.windowed: step must be >= 1")
    var list = seq is List ? seq : seq.toList
    var out = []
    var i = 0
    while (i + size <= list.count) {
      out.add(list[i...i + size])
      i = i + step
    }
    return out
  }

  // -- Pairing -----------------------------------------------------------

  /// Pairwise zip. Length = `min(a, b)`. Each pair is a 2-element
  /// list `[a_i, b_i]`.
  ///
  /// ```wren
  /// FP.zip([1, 2, 3], ["a", "b"])   //= [[1, "a"], [2, "b"]]
  /// ```
  static zip(a, b) {
    var la = a is List ? a : a.toList
    var lb = b is List ? b : b.toList
    var n = la.count < lb.count ? la.count : lb.count
    var out = []
    var i = 0
    while (i < n) {
      out.add([la[i], lb[i]])
      i = i + 1
    }
    return out
  }

  /// Combine two sequences pairwise with `fn(a_i, b_i)`. Like
  /// `zip(a, b).map {|p| fn(p[0], p[1])}` but skips the
  /// intermediate pair allocation.
  static zipWith(a, b, fn) {
    var la = a is List ? a : a.toList
    var lb = b is List ? b : b.toList
    var n = la.count < lb.count ? la.count : lb.count
    var out = []
    var i = 0
    while (i < n) {
      out.add(fn.call(la[i], lb[i]))
      i = i + 1
    }
    return out
  }

  /// Invert of `zip`. Given `[[a0, b0], [a1, b1], ...]` returns
  /// `[[a0, a1, ...], [b0, b1, ...]]`. Inner lists must all be
  /// 2-element.
  static unzip(pairs) {
    var a = []
    var b = []
    for (p in pairs) {
      a.add(p[0])
      b.add(p[1])
    }
    return [a, b]
  }

  /// Attach a running index. `[x0, x1, ...]` becomes
  /// `[[0, x0], [1, x1], ...]`.
  static withIndex(seq) {
    var out = []
    var i = 0
    for (x in seq) {
      out.add([i, x])
      i = i + 1
    }
    return out
  }

  // -- Sorting -----------------------------------------------------------

  /// Copy + sort with the default comparator. `Num` / `String`
  /// compare the obvious way; mixed types fall back to Wren's
  /// built-in `<` which may abort.
  static sorted(seq) {
    var out = seq is List ? seq.toList : seq.toList
    out.sort()
    return out
  }

  /// Copy + sort using `fn(a, b) -> Bool`. `true` means `a <= b`
  /// (stable with that convention).
  static sortedWith(seq, cmp) {
    var out = seq is List ? seq.toList : seq.toList
    out.sort(cmp)
    return out
  }

  /// Copy + sort by a key extractor. The default order is
  /// ascending; pass `descending: true` via `sortedByDesc` for
  /// the other direction.
  static sortedBy(seq, keyFn) {
    var out = seq is List ? seq.toList : seq.toList
    out.sort(Fn.new {|a, b| keyFn.call(a) < keyFn.call(b) })
    return out
  }

  /// Descending variant. Shorthand so callers don't have
  /// to remember which side of the comparator to flip.
  static sortedByDesc(seq, keyFn) {
    var out = seq is List ? seq.toList : seq.toList
    out.sort(Fn.new {|a, b| keyFn.call(a) > keyFn.call(b) })
    return out
  }

  // -- Scans / bounded iteration -----------------------------------------

  /// Prefix reductions: returns a list of intermediate
  /// accumulators, including the initial one.
  ///
  /// ```wren
  /// FP.scan([1, 2, 3, 4], 0, Fn.new {|acc, x| acc + x })
  /// //= [0, 1, 3, 6, 10]
  /// ```
  static scan(seq, init, fn) {
    var out = [init]
    var acc = init
    for (x in seq) {
      acc = fn.call(acc, x)
      out.add(acc)
    }
    return out
  }

  /// Stop taking as soon as `pred(x)` is false.
  ///
  /// ```wren
  /// FP.takeWhile([1, 2, 3, 0, 5], Fn.new {|n| n > 0 })
  /// //= [1, 2, 3]
  /// ```
  static takeWhile(seq, pred) {
    var out = []
    for (x in seq) {
      if (!pred.call(x)) break
      out.add(x)
    }
    return out
  }

  /// Skip while `pred(x)` is true; take the remainder once the
  /// predicate first flips to false (even if it later returns to
  /// true).
  ///
  /// ```wren
  /// FP.dropWhile([1, 2, 3, 0, 5], Fn.new {|n| n > 0 })
  /// //= [0, 5]
  /// ```
  static dropWhile(seq, fn) {
    var list = seq is List ? seq : seq.toList
    var start = 0
    while (start < list.count && fn.call(list[start])) {
      start = start + 1
    }
    var out = []
    var i = start
    while (i < list.count) {
      out.add(list[i])
      i = i + 1
    }
    return out
  }

  // -- Deduplication -----------------------------------------------------

  /// Remove consecutive duplicates and keep the first occurrence
  /// of each value overall. Compares with Wren's `==`.
  static distinct(seq) {
    var seen = []
    var out = []
    for (x in seq) {
      if (!seen.contains(x)) {
        seen.add(x)
        out.add(x)
      }
    }
    return out
  }

  /// Deduplicate by a key extractor. Uses a `Map` so `keyFn` must
  /// return a hashable (`String` / `Num` / `Bool` / `null` are
  /// safe).
  ///
  /// ```wren
  /// FP.distinctBy(["apple", "ant", "bee"], Fn.new {|s| s[0] })
  /// //= ["apple", "bee"]
  /// ```
  static distinctBy(seq, keyFn) {
    var seen = {}
    var out = []
    for (x in seq) {
      var k = keyFn.call(x)
      if (!seen.containsKey(k)) {
        seen[k] = true
        out.add(x)
      }
    }
    return out
  }

  // -- Element access ----------------------------------------------------

  /// First element, or null on empty. Preserves the semantics
  /// already on `Sequence` without forcing a full `.toList`.
  static first(seq) {
    for (x in seq) return x
    return null
  }

  /// First element matching a predicate (or null).
  static firstWhere(seq, pred) {
    for (x in seq) {
      if (pred.call(x)) return x
    }
    return null
  }

  /// Last element. O(n) for anything but a List, since the
  /// iterator is walked to the end. Null on empty.
  static last(seq) {
    var result = null
    var seen = false
    for (x in seq) {
      result = x
      seen = true
    }
    return seen ? result : null
  }

  /// Last element matching a predicate.
  static lastWhere(seq, pred) {
    var result = null
    for (x in seq) {
      if (pred.call(x)) result = x
    }
    return result
  }

  /// -- Extrema ----------------------------------------------------------

  static min(seq) {
    var best = null
    var seen = false
    for (x in seq) {
      if (!seen || x < best) {
        best = x
        seen = true
      }
    }
    return best
  }

  static max(seq) {
    var best = null
    var seen = false
    for (x in seq) {
      if (!seen || x > best) {
        best = x
        seen = true
      }
    }
    return best
  }

  /// Extrema with a key extractor. Returns the ELEMENT whose key
  /// is smallest/largest; the key itself is discarded. Null on
  /// empty input.
  static minBy(seq, keyFn) {
    var best = null
    var bestKey = null
    var seen = false
    for (x in seq) {
      var k = keyFn.call(x)
      if (!seen || k < bestKey) {
        best = x
        bestKey = k
        seen = true
      }
    }
    return best
  }

  static maxBy(seq, keyFn) {
    var best = null
    var bestKey = null
    var seen = false
    for (x in seq) {
      var k = keyFn.call(x)
      if (!seen || k > bestKey) {
        best = x
        bestKey = k
        seen = true
      }
    }
    return best
  }

  // -- Arithmetic --------------------------------------------------------

  /// Sum of a numeric sequence. Returns 0 for empty.
  static sum(seq) {
    var s = 0
    for (x in seq) s = s + x
    return s
  }

  /// Sum of `fn(x)` over the sequence.
  static sumBy(seq, fn) {
    var s = 0
    for (x in seq) s = s + fn.call(x)
    return s
  }

  // -- Concatenation / reverse ------------------------------------------

  /// Concatenate two sequences end-to-end into a new list.
  static concat(a, b) {
    var out = []
    for (x in a) out.add(x)
    for (x in b) out.add(x)
    return out
  }

  /// Reverse order. O(n); materialises into a list.
  static reversed(seq) {
    var list = seq is List ? seq : seq.toList
    var out = []
    var i = list.count - 1
    while (i >= 0) {
      out.add(list[i])
      i = i - 1
    }
    return out
  }

  // -- Map construction --------------------------------------------------

  /// Build a `Map` by running each element through `fn` and
  /// expecting `[key, value]` pairs.
  ///
  /// ```wren
  /// FP.toMap([1, 2, 3], Fn.new {|n| [n.toString, n * n] })
  /// //= { "1": 1, "2": 4, "3": 9 }
  /// ```
  ///
  /// Later pairs with the same key overwrite earlier ones.
  static toMap(seq, fn) {
    var out = {}
    for (x in seq) {
      var pair = fn.call(x)
      out[pair[0]] = pair[1]
    }
    return out
  }
}

/// Fluent wrapper. Every non-terminal method rewraps into a new
/// `Pipe` so chains compose.
///
/// ```wren
/// Pipe.of([1, 2, 3, 4])
///   .where   (Fn.new {|n| n % 2 == 0 })
///   .map     (Fn.new {|n| n * 10 })
///   .toList                               //= [20, 40]
/// ```
///
/// Terminals: `toList`, `reduce(_)`, `reduce(_, _)`, `sum`,
/// `count`, `first(_)`, `last(_)`, `toMap(_)`, `each(_)`,
/// `any(_)`, `all(_)`, `contains(_)`, `isEmpty`, `join()`,
/// `join(_)`, `min`, `max`, `unwrap`.
///
/// Everything else returns a fresh `Pipe`, so `.tap` / `.map` /
/// `.where` etc. can interleave without materialising a separate
/// variable for each step.
class Pipe {
  construct of(seq) { _seq = seq }

  /// Escape hatch: hand back the current sequence unwrapped.
  unwrap { _seq }

  /// -- Terminals (return a concrete value) -------------------------------

  toList                { _seq is List ? _seq : _seq.toList }
  reduce(fn)            { _seq.reduce(fn) }
  reduce(init, fn)      { _seq.reduce(init, fn) }
  sum                   { FP.sum(_seq) }
  sumBy(fn)             { FP.sumBy(_seq, fn) }
  count                 { _seq.count }
  count(fn)             { _seq.count(fn) }
  first                 { FP.first(_seq) }
  first(fn)             { FP.firstWhere(_seq, fn) }
  last                  { FP.last(_seq) }
  last(fn)              { FP.lastWhere(_seq, fn) }
  min                   { FP.min(_seq) }
  max                   { FP.max(_seq) }
  minBy(fn)             { FP.minBy(_seq, fn) }
  maxBy(fn)             { FP.maxBy(_seq, fn) }
  each(fn)              { _seq.each(fn) }
  any(fn)               { _seq.any(fn) }
  all(fn)               { _seq.all(fn) }
  contains(v)           { _seq.contains(v) }
  isEmpty               { _seq.isEmpty }
  join()                { _seq.join() }
  join(sep)             { _seq.join(sep) }
  toMap(fn)             { FP.toMap(_seq, fn) }
  groupBy(fn)           { FP.groupBy(_seq, fn) }
  partition(fn)         { FP.partition(_seq, fn) }

  /// -- Non-terminals (return a new Pipe) ---------------------------------

  map(fn)               { Pipe.of(_seq.map(fn)) }
  where(fn)             { Pipe.of(_seq.where(fn)) }
  filter(fn)            { Pipe.of(_seq.where(fn)) }
  take(n)               { Pipe.of(_seq.take(n)) }
  skip(n)               { Pipe.of(_seq.skip(n)) }
  flatMap(fn)           { Pipe.of(FP.flatMap(_seq, fn)) }
  tap(fn)               { Pipe.of(FP.tap(_seq, fn)) }
  chunked(n)            { Pipe.of(FP.chunked(_seq, n)) }
  windowed(n)           { Pipe.of(FP.windowed(_seq, n)) }
  windowed(n, step)     { Pipe.of(FP.windowed(_seq, n, step)) }
  sorted                { Pipe.of(FP.sorted(_seq)) }
  sortedBy(fn)          { Pipe.of(FP.sortedBy(_seq, fn)) }
  sortedByDesc(fn)      { Pipe.of(FP.sortedByDesc(_seq, fn)) }
  sortedWith(cmp)       { Pipe.of(FP.sortedWith(_seq, cmp)) }
  takeWhile(fn)         { Pipe.of(FP.takeWhile(_seq, fn)) }
  dropWhile(fn)         { Pipe.of(FP.dropWhile(_seq, fn)) }
  distinct              { Pipe.of(FP.distinct(_seq)) }
  distinctBy(fn)        { Pipe.of(FP.distinctBy(_seq, fn)) }
  reversed              { Pipe.of(FP.reversed(_seq)) }
  withIndex             { Pipe.of(FP.withIndex(_seq)) }
  concat(other)         { Pipe.of(FP.concat(_seq, other)) }
  zip(other)            { Pipe.of(FP.zip(_seq, other)) }
  zipWith(other, fn)    { Pipe.of(FP.zipWith(_seq, other, fn)) }
}
