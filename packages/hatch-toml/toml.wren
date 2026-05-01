// `@hatch:toml` — TOML parsing and serialization.
//
// ```wren
// import "@hatch:toml" for Toml
//
// var config = Toml.parse("""
//   name = "hatch"
//   version = "0.1.0"
//   [deps]
//   json = "1.0"
// """)
// config["name"]          // "hatch"
// config["deps"]["json"]  // "1.0"
//
// Toml.encode({
//   "name": "app",
//   "port": 8080,
//   "db": {"host": "localhost"}
// })
// // name = "app"
// // port = 8080
// // [db]
// // host = "localhost"
// ```
//
// ## Type mapping
//
// | TOML            | Wren                |
// |-----------------|---------------------|
// | string          | `String`            |
// | integer / float | `Num`               |
// | boolean         | `Bool`              |
// | datetime        | `String` (RFC 3339) |
// | array           | `List`              |
// | table           | `Map<String, _>`    |
//
// Encoding round-trips cleanly for everything except datetimes,
// which come back as `String`s — if you need a datetime output,
// pass it as a pre-formatted RFC 3339 string.
//
// Top-level value for `encode` must be a `Map` (TOML documents
// are always tables). Malformed input aborts the fiber with a
// message from the parser; wrap in `Fiber.new { … }.try()` to
// catch.
//
// Backed by the Rust `toml` crate — canonical behaviour for the
// full TOML v1.0.0 spec.

import "toml" for TomlCore

class Toml {
  /// Parse a TOML document. Returns a Map with all top-level keys.
  static parse(text) {
    if (!(text is String)) Fiber.abort("Toml.parse: text must be a string")
    return TomlCore.parse(text)
  }

  /// Serialize a Map to canonical TOML (compact inline-table form
  /// where possible, standard `[table]` headers otherwise).
  static encode(value) {
    if (!(value is Map)) Fiber.abort("Toml.encode: value must be a Map")
    return TomlCore.encode(value)
  }

  /// Same as `encode` but with the `toml` crate's pretty-printer —
  /// expands arrays onto multiple lines and adds some whitespace
  /// for human readability.
  static encodePretty(value) {
    if (!(value is Map)) Fiber.abort("Toml.encodePretty: value must be a Map")
    return TomlCore.encodePretty(value)
  }
}
