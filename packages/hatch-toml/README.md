A TOML parser and serializer backed by the Rust `toml` crate. One class — `Toml` — with `parse`, `encode`, and `encodePretty`. Canonical TOML v1.0.0 behaviour; pair with `@hatch:fs` for config files and with `@hatch:json` when you need to round-trip between formats.

## Overview

Top-level documents are always tables, so `Toml.parse` returns a `Map`. `Toml.encode` requires a `Map` for symmetric reasons — pass any nested mix of scalars, arrays, and tables and the encoder picks inline or `[header]` form per the canonical rules.

```wren
import "@hatch:toml" for Toml

var config = Toml.parse("""
  name = "hatch"
  version = "0.1.0"
  [deps]
  json = "1.0"
""")

System.print(config["name"])             // "hatch"
System.print(config["deps"]["json"])     // "1.0"

System.print(Toml.encode({
  "name": "app",
  "port": 8080,
  "db":   { "host": "localhost" }
}))
// name = "app"
// port = 8080
// [db]
// host = "localhost"
```

`Toml.encodePretty(value)` runs the same encoder with the crate's pretty-printer — multi-line arrays and a touch of whitespace for human readability.

## Type mapping

| TOML            | Wren        |
|-----------------|-------------|
| string          | `String`    |
| integer / float | `Num`       |
| boolean         | `Bool`      |
| datetime        | `String` (RFC 3339) |
| array           | `List`      |
| table           | `Map<String, _>` |

Encoding round-trips cleanly for everything except datetimes, which come back as `String`s. If you need a datetime in the output, pass it as a pre-formatted RFC 3339 string.

> **Note — fallible parsing**
> Malformed input aborts the fiber with a message from the parser. Wrap in `Fiber.new { Toml.parse(text) }.try()` when you want graceful recovery (config-file loaders, mostly).

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Native only — `#!wasm` builds need a separate WASM-compiled `toml` bridge that hasn't shipped yet. Pair with `@hatch:fs` for config-file loading.
