// `@hatch:random`: random numbers, sampling, shuffling.
//
// ```wren
// import "@hatch:random" for Rand
//
// Rand.float              // 0.0 ≤ x < 1.0
// Rand.float(10)          // 0.0 ≤ x < 10.0
// Rand.float(-1, 1)       // -1.0 ≤ x < 1.0
// Rand.int(6)             // 0 ≤ n < 6
// Rand.int(1, 7)          // 1 ≤ n < 7   (dice)
// Rand.bool               // 50/50 true/false
// Rand.sample(["a", "b", "c"])        // one element
// Rand.sample([1,2,3,4,5], 2)         // k distinct elements
// Rand.shuffle([1,2,3])   // in place; returns the list
//
// // Seed the shared default stream for deterministic runs
// // (useful in tests, bench harnesses, etc.).
// Rand.seed = 42
//
// // For independent / reproducible streams, grab a fresh one:
// var stream = Rand.stream(99)
// stream.int(100)
// stream.int(100)         // different draw, same seeded sequence
// ```
//
// Static `Rand.*` methods all route through a single module-level
// default stream. That stream is initialised unseeded at import
// time. Set `Rand.seed = n` for reproducibility across a whole
// program. For per-call reproducibility or concurrent streams,
// hold a separate `Rand.stream(seed)` handle.
//
// Backed by the runtime's built-in `Random` module (xoshiro256++
// PRNG). `sample` and `shuffle` are uniform; `int` is free of
// modulo bias for small ranges.

import "random" for Random

// Shared default stream. Module var so `Rand.seed=(n)` can
// reassign it on demand. Zero-arg `Random.new` is registered
// as a getter, not a method call, hence no parens.
var default_ = Random.new

class Rand {
  // --- Scalar draws -----------------------------------------------------

  static float              { default_.float() }
  static float(max)         { default_.float(max) }
  static float(min, max)    { default_.float(min, max) }

  static int(max)           { default_.int(max) }
  static int(min, max)      { default_.int(min, max) }

  static bool               { default_.int(2) == 1 }

  // --- Collection helpers -----------------------------------------------

  /// One uniformly-random element of `list`. Aborts if empty.
  static sample(list)       { default_.sample(list) }
  /// `count` distinct elements of `list`, random order. Aborts if
  /// count > list.count.
  static sample(list, count){ default_.sample(list, count) }

  /// Fisher-Yates in place. Returns the list so calls can chain.
  static shuffle(list)      { default_.shuffle(list) }

  // --- Stream management -----------------------------------------------

  /// Seed the shared default stream. Accepts any `Num`; the PRNG
  /// converts internally. Useful for deterministic tests:
  ///
  /// ```wren
  /// Rand.seed = 1234
  /// Rand.int(100) // always the same sequence across runs
  /// ```
  static seed=(n) {
    if (!(n is Num)) Fiber.abort("Rand.seed: must be a number")
    default_ = Random.new(n)
  }

  /// Grab an independent stream. Use when you want reproducibility
  /// without touching the shared default, or when multiple fibers
  /// need uncorrelated sequences.
  static stream()           { Random.new }
  static stream(seed)       { Random.new(seed) }
}
