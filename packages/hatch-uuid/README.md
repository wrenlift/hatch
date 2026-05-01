UUID v4, v5, and v7 generation plus parsing and 16-byte conversion. One class — `Uuid` — with constants for the four RFC 4122 namespaces (`NS_DNS`, `NS_URL`, `NS_OID`, `NS_X500`), validation helpers, and round-trip byte conversion. Backed by the Rust `uuid` crate.

## Overview

Pick the version that matches the property you want — random, deterministic, or time-ordered — and keep going.

```wren
import "@hatch:uuid" for Uuid

System.print(Uuid.v4)          // "8f14e45f-ceea-467a-9575-f86bb6a20b12" — random
System.print(Uuid.v7)          // "0190f9a8-12ab-7b4e-..." — time-ordered
System.print(Uuid.nil)         // "00000000-0000-0000-0000-000000000000"

System.print(Uuid.v5("dns", "example.com"))
System.print(Uuid.v5(Uuid.NS_URL, "https://example.com/path"))
```

| Version | Use it for | Notes |
|---------|------------|-------|
| `v4`    | Arbitrary random identifiers | Best general-purpose default. |
| `v5`    | Deterministic ids from strings | SHA-1 over `(namespace, name)` — same inputs produce the same UUID. |
| `v7`    | Database primary keys | Time-ordered prefix preserves B-tree locality on inserts. |

`Uuid.v5(namespace, name)` accepts either an `NS_*` constant, the short alias (`"dns"` / `"url"` / `"oid"` / `"x500"`), or any plain UUID string for a custom namespace.

## Parsing and bytes

`Uuid.parse(text)` returns the canonical hyphenated lower-case form on success or `null` on malformed input — that's a soft check, no fiber abort. `Uuid.isValid(text)` is the boolean form. `Uuid.version(text)` reports `1`-`7` or `null`.

```wren
System.print(Uuid.parse("550E8400-E29B-41D4-A716-446655440000"))
// "550e8400-e29b-41d4-a716-446655440000"

var bytes = Uuid.toBytes("550e8400-e29b-41d4-a716-446655440000")
System.print(bytes.count)                  // 16
System.print(Uuid.fromBytes(bytes))        // round-trips back to the canonical string
```

> **Tip — pick v7 for database keys**
> v4 keys are uniformly distributed, which thrashes B-tree pages on insert. v7 keys carry a millisecond timestamp prefix, so new rows land near each other on disk. The collision space stays effectively infinite, you just keep your indexes hot.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Native only — `#!wasm` builds need a separate WASM-compiled UUID bridge. Pair with `@hatch:sqlite` or `@hatch:json` when persisting / serialising.
