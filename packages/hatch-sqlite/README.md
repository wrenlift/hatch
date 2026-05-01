Embedded SQLite for Wren. `Database.open(path)` (or `Database.openMemory()`) returns a connection; statements bind parameters positionally or by name; `query` iterates rows as `Map`s keyed by column. Backed by `rusqlite` with bundled SQLite — no external system dependency on the runtime host.

## Overview

Open a database, run statements, query for results. Parameters bind either as a positional `List` for `?` placeholders or as a `Map` for `:name` placeholders. Rows come back as `Map<String, Value>` so columns are accessed by name without an explicit schema struct.

```wren
import "@hatch:sqlite" for Database

var db = Database.openMemory()
db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
db.execute("INSERT INTO users (name, age) VALUES (?, ?)", ["alice", 30])
db.execute("INSERT INTO users (name, age) VALUES (?, ?)", ["bob",   25])

for (row in db.query("SELECT * FROM users WHERE age > ? ORDER BY id", [20])) {
  System.print("%(row["id"]) — %(row["name"]) (%(row["age"]))")
}

db.execute("UPDATE users SET age = :age WHERE name = :name", {
  "age":  31,
  "name": "alice"
})

db.close
```

`db.execute` returns the number of rows affected; `db.lastInsertRowid` gives the auto-incremented id of the most recent insert.

## Transactions

`db.transaction { ... }` commits on clean fiber return and rolls back on a `Fiber.abort` inside the block. This is the right shape for batch inserts where you want all-or-nothing semantics:

```wren
db.transaction {
  db.execute("INSERT INTO users (name) VALUES (?)", ["carol"])
  db.execute("INSERT INTO users (name) VALUES (?)", ["dan"])
}
```

If the second insert aborts (constraint violation, etc.), the first one rolls back too.

## Type mapping

| SQL       | Wren        | Notes |
|-----------|-------------|-------|
| `NULL`    | `Null`      |       |
| `INTEGER` | `Num`       | Values above 2^53 lose precision — they round to the nearest representable double. |
| `REAL`    | `Num`       |       |
| `TEXT`    | `String`    |       |
| `BLOB`    | `List<Num>` | Each byte in `0..=255`. |

> **Warning — large integers lose precision**
> Wren's `Num` is an IEEE 754 double, so SQLite `INTEGER` values above 2^53 round on the way through. If you store unsigned 64-bit ids, encode them as `TEXT` (or as `BLOB` for binary fixed-width keys) to keep the bits intact.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Native only — `#!wasm` builds need a separate WASM-compiled SQLite that hasn't shipped yet. The dylib is bundled into the package's `.hatch` artifact, so the runtime host never needs SQLite installed.
