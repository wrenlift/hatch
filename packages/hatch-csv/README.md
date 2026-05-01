An RFC 4180 CSV parser and serializer. Handles quoting, embedded newlines, and header rows; mixed line endings (`\r\n`, `\n`, bare `\r`) all terminate a row on parse. One class — `Csv` — with a `parse` / `encode` pair, configured by an options `Map`.

## Overview

By default `Csv.parse` returns `List<List<String>>` and `Csv.encode` accepts the same shape. Pass `{"header": true}` and parse switches to `List<Map<String, String>>` keyed by the first row; encode emits a header row derived from the first record's keys (or from an explicit `columns` list).

```wren
import "@hatch:csv" for Csv

var rows = Csv.parse("a,b,c\n1,2,3\n4,5,6")
System.print(rows[1][2]) // "3"

var people = Csv.parse(
  "name,age\nalice,30\nbob,25",
  { "header": true }
)
System.print(people[0]["name"]) // "alice"

System.print(Csv.encode(
  [{ "name": "alice", "age": 30 }, { "name": "bob", "age": 25 }],
  { "header": true, "columns": ["name", "age"] }
))
// name,age\r\nalice,30\r\nbob,25\r\n
```

`encode` stringifies `Num`, `Bool`, and `null` via `toString` (with `null` becoming an empty cell). Strings are quoted when they contain the delimiter, the quote character, or a newline. Anything else aborts the calling fiber.

## Options

| Key          | Where        | Default | Notes |
|--------------|--------------|---------|-------|
| `delimiter`  | parse + enc  | `,`     | Must be a one-character string. |
| `quote`      | parse + enc  | `"`     | Must be a one-character string. |
| `header`     | parse + enc  | `false` | Parse → `List<Map>`; encode → emit header row. |
| `columns`    | encode       | —       | Explicit column order for `Map` rows; recommended when layout matters. |
| `lineEnding` | encode       | `\r\n`  | Switch to `\n` for Unix-only output. |

> **Note — column order is your job**
> Wren `Map` iteration order isn't guaranteed across runtime versions. When encoding maps and the column layout has to be stable, pass `columns` explicitly rather than relying on the first record's key order.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Pure-Wren — no native dependencies, no host capabilities.
