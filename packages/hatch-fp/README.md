Fluent and functional collection operations: `flatMap`, `groupBy`, `partition`, `zipWith`, `sortedBy`, `chunked`, `windowed`, `scan`, `distinct`, `tap`, `takeWhile`, `dropWhile`, plus the usual suspects. Two surfaces: a `FP` static toolbox to call directly, and a `Pipe` builder for fluent left-to-right chains. Pure Wren, with no runtime module, so the JIT tier-ups it like any hot user code.

## Overview

Wren's built-in `Sequence` already covers `map`, `where`, `take`, `skip`, `reduce`, `each`, `count`, `any`, `all`, `contains`, `join`, `toList`. This package layers the rest on top.

```wren
import "@hatch:fp" for FP, Pipe

System.print(FP.flatMap([[1, 2], [3]], Fn.new {|xs| xs }))
// [1, 2, 3]

System.print(FP.groupBy([1, 2, 3, 4], Fn.new {|n| n % 2 }))
// { 1: [1, 3], 0: [2, 4] }

System.print(FP.zipWith([1, 2, 3], [10, 20, 30], Fn.new {|a, b| a + b }))
// [11, 22, 33]
```

`Pipe` chains compose left-to-right. Each op eagerly materialises into a `List`, so long chains stay O(n) per step. Terminate the pipeline with `toList`, `reduce`, `first`, `last`, etc.

```wren
var squares = Pipe.of(1..10)
  .where(Fn.new {|n| n % 2 == 0 })
  .map  (Fn.new {|n| n * n })
  .take (3)
  .toList
// [4, 16, 36]
```

## Defaults and helpers

`FP.identity`, `FP.constant(v)`, and `FP.noop` cover the common slot-fillers. Pass them as the default key-extractor for `distinctBy`, the default value for `map(FP.constant(0))`, or the default body for `tap` when only a debug print is wanted. `FP.generate(n, fn)` and `FP.repeat(value, n)` are constructor shorthands; `FP.range(start, end)` covers `start..end` when a list is wanted eagerly.

> **Tip: eager materialisation is intentional.**
> Lazy iteration would mean dragging Wren's iterator protocol through every step. Eager `List` materialisation keeps each op O(n) and cheap to reason about, and the JIT optimises away the intermediate allocations on hot paths.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Pure-Wren, with no native dependencies and no host capabilities.
