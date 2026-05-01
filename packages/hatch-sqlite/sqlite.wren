// `@hatch:sqlite` — embedded SQLite.
//
// ```wren
// import "@hatch:sqlite" for Database
//
// var db = Database.openMemory()
// db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
// db.execute("INSERT INTO users (name, age) VALUES (?, ?)", ["alice", 30])
// db.execute("INSERT INTO users (name, age) VALUES (?, ?)", ["bob",   25])
//
// for (row in db.query("SELECT * FROM users WHERE age > ? ORDER BY id", [20])) {
//   System.print("%(row["id"]) — %(row["name"]) (%(row["age"]))")
// }
//
// // Named parameters:
// db.execute("UPDATE users SET age = :age WHERE name = :name", {
//   "age":  31,
//   "name": "alice"
// })
//
// // Transaction helper — commits on success, rolls back on abort.
// db.transaction {
//   db.execute("INSERT INTO users (name) VALUES (?)", ["carol"])
//   db.execute("INSERT INTO users (name) VALUES (?)", ["dan"])
// }
//
// db.close
// ```
//
// ## Type mapping
//
// | SQL value | Wren value                              |
// |-----------|-----------------------------------------|
// | `NULL`    | `null`                                  |
// | `INTEGER` | `Num` (beware: `>2^53` loses precision) |
// | `REAL`    | `Num`                                   |
// | `TEXT`    | `String`                                |
// | `BLOB`    | `List<Num>` (each byte `0..=255`)       |
//
// Backed by the `rusqlite` crate with bundled SQLite. The plugin
// ships as a platform-specific dylib inside this package's
// `.hatch` artifact — no external SQLite dependency on the
// runtime host.
//
// Error handling: all methods abort the fiber on failure. Wrap
// in `Fiber.new { ... }.try()` for fallible variants.

// The native plugin lives in a sibling cdylib (`wlift_sqlite`)
// that `hatch publish` bundles into this package. Each foreign
// method binds to a `#[no_mangle] extern "C" fn` in that dylib
// — the symbol naming convention is `wlift_sqlite_<action>`.
#!native = "wlift_sqlite"
foreign class SqliteCore {
  #!symbol = "wlift_sqlite_open"
  foreign static open(path)

  #!symbol = "wlift_sqlite_close"
  foreign static close(id)

  #!symbol = "wlift_sqlite_execute"
  foreign static execute(id, sql, params)

  #!symbol = "wlift_sqlite_query"
  foreign static query(id, sql, params)

  #!symbol = "wlift_sqlite_last_insert_rowid"
  foreign static lastInsertRowid(id)

  #!symbol = "wlift_sqlite_changes"
  foreign static changes(id)

  #!symbol = "wlift_sqlite_in_transaction"
  foreign static inTransaction(id)
}

/// Ergonomic wrapper over the foreign handles. Holds the connection
/// id privately; callers pass values and parameter lists and get
/// back Wren-shaped data.
class Database {
  // Open a database at `path`. Creates the file if missing.
  // `:memory:` gives an in-memory database — useful for tests.
  construct new_(id) {
    _id = id
  }

  static open(path) {
    if (!(path is String)) Fiber.abort("Database.open: path must be a string")
    return Database.new_(SqliteCore.open(path))
  }

  /// Shortcut for `Database.open(":memory:")`.
  static openMemory() { Database.open(":memory:") }

  id { _id }

  // --- Core operations --------------------------------------------------

  /// Run a statement (DDL or INSERT/UPDATE/DELETE). Returns the
  /// number of rows affected.
  execute(sql) { execute(sql, null) }
  execute(sql, params) {
    if (!(sql is String)) Fiber.abort("Database.execute: sql must be a string")
    checkAlive_()
    return SqliteCore.execute(_id, sql, params)
  }

  /// Run a SELECT. Returns a List<Map> — each map has lower-case
  /// column-name keys and Wren-typed values.
  query(sql) { query(sql, null) }
  query(sql, params) {
    if (!(sql is String)) Fiber.abort("Database.query: sql must be a string")
    checkAlive_()
    return SqliteCore.query(_id, sql, params)
  }

  /// First row of a SELECT, or null if empty.
  queryRow(sql) { queryRow(sql, null) }
  queryRow(sql, params) {
    var rows = query(sql, params)
    return rows.count == 0 ? null : rows[0]
  }

  // --- Metadata ---------------------------------------------------------

  lastInsertRowid { SqliteCore.lastInsertRowid(_id) }
  changes         { SqliteCore.changes(_id) }
  inTransaction   { SqliteCore.inTransaction(_id) }

  // --- Transaction helper -----------------------------------------------
  /// ```wren
  /// db.transaction {
  ///   db.execute("INSERT ...")
  ///   db.execute("INSERT ...")
  /// }
  /// ```
  ///
  /// Commits if the block returns normally; rolls back if the
  /// block aborts. The abort propagates to the caller so failing
  /// blocks aren't silently eaten.
  transaction(fn) {
    if (!(fn is Fn)) Fiber.abort("Database.transaction: argument must be a Fn")
    checkAlive_()
    execute("BEGIN")
    var probed = Fiber.new { fn.call() }
    var result = probed.try()
    if (probed.error != null) {
      execute("ROLLBACK")
      Fiber.abort(probed.error)
    }
    execute("COMMIT")
    return result
  }

  // --- Lifecycle --------------------------------------------------------

  close {
    if (_id == null) return
    SqliteCore.close(_id)
    _id = null
  }

  checkAlive_() {
    if (_id == null) Fiber.abort("Database: use after close")
  }

  toString { "Database(id=%(_id))" }
}
