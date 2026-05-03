Fluent assertion primitives for Wren test specs. The package exposes one entry point, `Expect.that(value)`, and a chainable `Assertion` to build matchers off of. Pairs with `@hatch:test` for a runner, but a failing assertion is a plain `Fiber.abort`, so any `wlift foo.spec.wren` invocation surfaces the failure as a normal abort.

## Overview

Read `Expect.that(x).toBe(y)` left-to-right and it's the same sentence in code and English. Matchers are direct: `.toBe`, `.toEqual`, `.toBeNull`, `.toBeTruthy`, `.toContain`, `.toBeInstanceOf`, `.toAbort`. Negation lives on the chain itself; `.not.toBeNull()` flips the next matcher.

```wren
import "@hatch:assert" for Expect

Expect.that(1 + 1).toBe(2)
Expect.that([1, 2, 3]).toEqual([1, 2, 3])
Expect.that(null).toBeNull()
Expect.that(42).not.toBeNull()
Expect.that(Fn.new { boom() }).toAbort()
```

`toBe` is reference equality (`==`); `toEqual` walks `List` and `Map` structurally so two distinct list instances with the same elements compare equal.

## Failure semantics

Every matcher aborts the calling fiber on failure with a formatted message. `@hatch:test` catches that abort and attributes it to the enclosing `it` block; standalone runs surface the same message as a top-level fiber abort.

```wren
Expect.that(Fn.new { Fiber.abort("nope") }).toAbortWith("nope")
```

`toAbort` and `toAbortWith` take a zero-arg `Fn` so the assertion controls when the body runs; it gets wrapped in a fresh `Fiber.new(...).try()` internally. Don't pass a pre-aborted fiber.

> **Note: Wren truthiness**
> `toBeTruthy` follows Wren's rules: only `false` and `null` are falsy. `0`, `""`, and empty collections are truthy. If you actually want "non-empty list," check `count` directly.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. No host capabilities required; pure-Wren implementation.
