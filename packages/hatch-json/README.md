A pure-Wren JSON parser and serializer. One class — `JSON` — with `parse`, `encode`, and a hook for custom types via a `toJson()` method on your class. No native dependencies; the JIT optimises it like any other hot Wren code.

## Overview

The type mapping is the obvious one. Numbers stay `Num`; strings stay `String`; arrays become `List`; objects become `Map` with string keys. Pass an `indent` to `encode` to switch to pretty-printed output.

```wren
import "@hatch:json" for JSON

System.print(JSON.parse("[1, 2, 3]"))             // [1, 2, 3]
System.print(JSON.parse("{\"a\": true}")["a"])    // true

System.print(JSON.encode({ "x": [1, 2] }))        // {"x":[1,2]}
System.print(JSON.encode({ "x": 1 }, 2))          // pretty, 2-space indent
```

| JSON         | Wren        |
|--------------|-------------|
| `null`       | `Null`      |
| `true/false` | `Bool`      |
| number       | `Num`       |
| string       | `String`    |
| array        | `List`      |
| object       | `Map`       |

## Custom types

Define `toJson()` on your class and the encoder will pick it up. The method returns any JSON-encodable value — typically a `Map` of fields. The encoder recurses on the returned value, so nested custom objects round-trip cleanly.

```wren
class Point {
  construct new(x, y) {
    _x = x
    _y = y
  }
  toJson() { { "x": _x, "y": _y } }
}

System.print(JSON.encode(Point.new(1, 2)))
// {"x":1,"y":2}
```

> **Note — fallible parsing means `Fiber.try()`**
> Malformed input aborts with a message pointing at the offending byte offset. Wrap the call in `Fiber.new { JSON.parse(text) }.try()` when you want graceful recovery rather than a top-level fiber abort.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Pure-Wren — no native dependencies, no host capabilities. Pairs with `@hatch:http` for API clients, with `@hatch:fs` for config files.
