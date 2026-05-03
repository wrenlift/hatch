// `@hatch:uuid`: UUID generation and parsing.
//
// ```wren
// import "@hatch:uuid" for Uuid
//
// Uuid.v4        // "8f14e45f-ceea-467a-9575-f86bb6a20b12" (random)
// Uuid.v7        // "0190f9a8-12ab-7b4e-9d3e-..." (time-ordered)
// Uuid.nil       // "00000000-0000-0000-0000-000000000000"
//
// // Namespaced, deterministic (RFC 4122 v5, SHA-1).
// Uuid.v5("dns", "example.com")
// Uuid.v5(Uuid.NS_URL, "https://example.com/path")
//
// // Parse + validate. Returns the canonical hyphenated lower-case
// // form, or null on malformed input.
// Uuid.parse("550E8400-E29B-41D4-A716-446655440000")
//   // returns "550e8400-e29b-41d4-a716-446655440000"
// Uuid.isValid("not-a-uuid")                 // false
// Uuid.version("0190f9a8-12ab-7b4e-9d3e-...")  // 7
//
// // Binary form (16 bytes).
// Uuid.toBytes("550e8400-e29b-41d4-a716-446655440000")  // [85, 14, ...]
// Uuid.fromBytes(bytes)                                  // returns the string
// ```
//
// ## Version guidance
//
// | Version | Use                                                            |
// |---------|----------------------------------------------------------------|
// | `v4`    | Arbitrary random identifiers.                                  |
// | `v5`    | Stable ids derived from strings (think "slug to UUID").        |
// | `v7`    | DB primary keys; time-ordered preserves B-tree locality.       |
//
// Backed by the `uuid` crate.

import "uuid" for UuidCore

class Uuid {
  /// RFC 4122 namespace constants. Pass either one of these or a
  /// plain UUID string to `Uuid.v5(namespace, name)`. The short
  /// strings "dns" / "url" / "oid" / "x500" are also accepted.
  static NS_DNS  { "6ba7b810-9dad-11d1-80b4-00c04fd430c8" }
  static NS_URL  { "6ba7b811-9dad-11d1-80b4-00c04fd430c8" }
  static NS_OID  { "6ba7b812-9dad-11d1-80b4-00c04fd430c8" }
  static NS_X500 { "6ba7b814-9dad-11d1-80b4-00c04fd430c8" }

  // --- Generators ------------------------------------------------

  static v4 { UuidCore.v4() }
  static v7 { UuidCore.v7() }

  static v5(namespace, name) {
    if (!(namespace is String)) Fiber.abort("Uuid.v5: namespace must be a string")
    if (!(name is String))      Fiber.abort("Uuid.v5: name must be a string")
    return UuidCore.v5(namespace, name)
  }

  static nil { UuidCore.nil() }

  // --- Parsing / validation --------------------------------------

  /// Returns the canonical form on success, null on failure.
  static parse(text) {
    if (!(text is String)) Fiber.abort("Uuid.parse: text must be a string")
    return UuidCore.parse(text)
  }

  static isValid(text) {
    if (!(text is String)) Fiber.abort("Uuid.isValid: text must be a string")
    return UuidCore.isValid(text)
  }

  /// Returns the version number (1-7) or null on malformed input.
  static version(text) {
    if (!(text is String)) Fiber.abort("Uuid.version: text must be a string")
    return UuidCore.version(text)
  }

  // --- Byte form -------------------------------------------------

  /// 16-byte canonical form as `List<Num>`.
  static toBytes(text) {
    if (!(text is String)) Fiber.abort("Uuid.toBytes: text must be a string")
    return UuidCore.toBytes(text)
  }

  /// 16-byte list to canonical UUID string. Any length other than 16
  /// aborts; values must be integers in 0..=255.
  static fromBytes(bytes) {
    if (!(bytes is List)) Fiber.abort("Uuid.fromBytes: bytes must be a list")
    return UuidCore.fromBytes(bytes)
  }
}
