Random numbers, sampling, and shuffles. A single `Rand` class exposes one-shot statics that share a module-level default stream, plus `Rand.stream(seed)` for an independent reproducible stream. Backed by the runtime's xoshiro256++ PRNG. `sample` and `shuffle` are uniform, and `int` is free of modulo bias on small ranges.

## Overview

The static surface covers the everyday cases: floats, ints, booleans, sampling, and shuffling. Pick one method, call it, move on.

```wren
import "@hatch:random" for Rand

System.print(Rand.float)               // 0.0 ≤ x < 1.0
System.print(Rand.float(10))           // 0.0 ≤ x < 10.0
System.print(Rand.float(-1, 1))        // -1.0 ≤ x < 1.0
System.print(Rand.int(6))              // 0 ≤ n < 6
System.print(Rand.int(1, 7))           // 1 ≤ n < 7  (dice)
System.print(Rand.bool)

System.print(Rand.sample(["a", "b", "c"]))      // one element
System.print(Rand.sample([1, 2, 3, 4, 5], 2))   // k distinct elements
Rand.shuffle([1, 2, 3])                          // in place, returns the list
```

`int(min, max)` is half-open: `Rand.int(1, 7)` rolls a six-sided die. `sample(list, k)` aborts if `k > list.count`; pass `list.count` exactly for a permutation. `shuffle` is Fisher-Yates and returns the list so calls chain.

## Seeded and independent streams

Set `Rand.seed = n` to make the shared default stream reproducible. Useful in tests and benchmark harnesses that need stable draws across runs.

```wren
Rand.seed = 42
System.print(Rand.int(100))   // always the same first draw
```

For per-component reproducibility, or for concurrent fibers that should not share state, hold a separate `Rand.stream(seed)` handle. Each stream advances independently and produces the same sequence given the same seed.

```wren
var npc = Rand.stream(0xc0ffee)
var loot = Rand.stream(0xdeadbeef)
```

> **Note: not a CSPRNG**
> xoshiro256++ is suitable for games, simulations, fuzzing, and other stochastic uses where security is not a concern. For keys, nonces, or password salts, use `@hatch:crypto`'s `Crypto.bytes(n)` (OS-seeded CSPRNG) instead.

## Compatibility

Wren 0.4 with WrenLift runtime 0.1 or newer. Pure Wren on top of the runtime's built-in `Random` module. Works on every supported target.
