import "./sqlite"      for Database, SqliteCore
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- Connection lifecycle --------------------------------------

Test.describe("Database lifecycle") {
  Test.it("open + close :memory:") {
    var db = Database.openMemory()
    Expect.that(db.id > 0).toBe(true)
    db.close
  }
  Test.it("close is idempotent") {
    var db = Database.openMemory()
    db.close
    db.close
  }
  Test.it("use after close aborts") {
    var db = Database.openMemory()
    db.close
    var e = Fiber.new { db.execute("SELECT 1") }.try()
    Expect.that(e).toContain("use after close")
  }
  Test.it("open with non-string aborts") {
    var e = Fiber.new { Database.open(42) }.try()
    Expect.that(e).toContain("must be a string")
  }
}

// --- DDL + DML -------------------------------------------------

Test.describe("execute") {
  Test.it("CREATE + INSERT + SELECT round-trip") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)")
    var inserted = db.execute("INSERT INTO t (name) VALUES (?)", ["alice"])
    Expect.that(inserted).toBe(1)
    var rows = db.query("SELECT * FROM t")
    Expect.that(rows.count).toBe(1)
    Expect.that(rows[0]["name"]).toBe("alice")
    db.close
  }
  Test.it("multiple inserts report rows affected") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (v INTEGER)")
    db.execute("INSERT INTO t VALUES (1)")
    db.execute("INSERT INTO t VALUES (2)")
    db.execute("INSERT INTO t VALUES (3)")
    var affected = db.execute("UPDATE t SET v = v * 10")
    Expect.that(affected).toBe(3)
    db.close
  }
  Test.it("changes reports last exec's count") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (v INTEGER)")
    db.execute("INSERT INTO t VALUES (1), (2), (3)")
    db.execute("DELETE FROM t WHERE v > 1")
    Expect.that(db.changes).toBe(2)
    db.close
  }
  Test.it("lastInsertRowid returns the new row id") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)")
    db.execute("INSERT INTO t (v) VALUES (?)", [42])
    Expect.that(db.lastInsertRowid).toBe(1)
    db.execute("INSERT INTO t (v) VALUES (?)", [43])
    Expect.that(db.lastInsertRowid).toBe(2)
    db.close
  }
}

// --- Parameter binding -----------------------------------------

Test.describe("parameter binding") {
  Test.it("positional params") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (a TEXT, b INTEGER)")
    db.execute("INSERT INTO t VALUES (?, ?)", ["x", 1])
    var row = db.queryRow("SELECT a, b FROM t WHERE b = ?", [1])
    Expect.that(row["a"]).toBe("x")
    Expect.that(row["b"]).toBe(1)
    db.close
  }
  Test.it("named params (colon prefix optional)") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (a TEXT, b INTEGER)")
    db.execute("INSERT INTO t VALUES (:a, :b)", {"a": "y", "b": 2})
    var row = db.queryRow("SELECT a, b FROM t WHERE b = :b", {"b": 2})
    Expect.that(row["a"]).toBe("y")
    db.close
  }
  Test.it("null maps to SQL NULL") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (v TEXT)")
    db.execute("INSERT INTO t VALUES (?)", [null])
    var row = db.queryRow("SELECT v FROM t")
    Expect.that(row["v"]).toBeNull()
    db.close
  }
  Test.it("bool maps to 0/1 integer") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (v INTEGER)")
    db.execute("INSERT INTO t VALUES (?)", [true])
    db.execute("INSERT INTO t VALUES (?)", [false])
    var rows = db.query("SELECT v FROM t ORDER BY rowid")
    Expect.that(rows[0]["v"]).toBe(1)
    Expect.that(rows[1]["v"]).toBe(0)
    db.close
  }
  Test.it("blob round-trip as ByteArray") {
    // BIND a blob as a Wren `List<Num>` — backwards-compat with
    // pre-ByteArray callers. READ comes back as a `ByteArray`,
    // which behaves like a Sequence (`count`, `[_]`).
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (b BLOB)")
    db.execute("INSERT INTO t VALUES (?)", [[1, 2, 3, 255]])
    var row = db.queryRow("SELECT b FROM t")
    Expect.that(row["b"].count).toBe(4)
    Expect.that(row["b"][0]).toBe(1)
    Expect.that(row["b"][3]).toBe(255)
    db.close
  }
  Test.it("float stays REAL") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (v REAL)")
    db.execute("INSERT INTO t VALUES (?)", [1.5])
    Expect.that(db.queryRow("SELECT v FROM t")["v"]).toBe(1.5)
    db.close
  }
}

// --- Query shape -----------------------------------------------

Test.describe("query shape") {
  Test.it("rows are Maps with column-name keys") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (a INTEGER, b TEXT)")
    db.execute("INSERT INTO t VALUES (1, 'x')")
    var row = db.queryRow("SELECT a, b FROM t")
    Expect.that(row["a"]).toBe(1)
    Expect.that(row["b"]).toBe("x")
    db.close
  }
  Test.it("empty result is []") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (v INTEGER)")
    Expect.that(db.query("SELECT * FROM t").count).toBe(0)
    db.close
  }
  Test.it("queryRow returns null on empty result") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (v INTEGER)")
    Expect.that(db.queryRow("SELECT * FROM t")).toBeNull()
    db.close
  }
  Test.it("preserves column order via explicit SELECT list") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (a INTEGER, b INTEGER, c INTEGER)")
    db.execute("INSERT INTO t VALUES (1, 2, 3)")
    var row = db.queryRow("SELECT c, a, b FROM t")
    Expect.that(row["c"]).toBe(3)
    Expect.that(row["a"]).toBe(1)
    Expect.that(row["b"]).toBe(2)
    db.close
  }
}

// --- Transactions ----------------------------------------------

Test.describe("transactions") {
  Test.it("commit on success") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (v INTEGER)")
    db.transaction {
      db.execute("INSERT INTO t VALUES (1)")
      db.execute("INSERT INTO t VALUES (2)")
    }
    var rows = db.query("SELECT COUNT(*) AS n FROM t")
    Expect.that(rows[0]["n"]).toBe(2)
    db.close
  }
  Test.it("rollback on abort") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (v INTEGER)")
    var e = Fiber.new {
      db.transaction {
        db.execute("INSERT INTO t VALUES (1)")
        Fiber.abort("nope")
      }
    }.try()
    Expect.that(e).toContain("nope")
    Expect.that(db.query("SELECT COUNT(*) AS n FROM t")[0]["n"]).toBe(0)
    db.close
  }
  Test.it("inTransaction reflects state") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (v INTEGER)")
    Expect.that(db.inTransaction).toBe(false)
    db.execute("BEGIN")
    Expect.that(db.inTransaction).toBe(true)
    db.execute("COMMIT")
    Expect.that(db.inTransaction).toBe(false)
    db.close
  }
}

// --- Error handling --------------------------------------------

Test.describe("errors") {
  Test.it("syntax error aborts") {
    var db = Database.openMemory()
    var e = Fiber.new { db.execute("NOT SQL") }.try()
    Expect.that(e).toContain("Sqlite.execute")
    db.close
  }
  Test.it("unknown table aborts") {
    var db = Database.openMemory()
    var e = Fiber.new { db.query("SELECT * FROM nope") }.try()
    Expect.that(e).toContain("nope")
    db.close
  }
  Test.it("UNIQUE constraint surfaces") {
    var db = Database.openMemory()
    db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT UNIQUE)")
    db.execute("INSERT INTO t (v) VALUES (?)", ["x"])
    var e = Fiber.new { db.execute("INSERT INTO t (v) VALUES (?)", ["x"]) }.try()
    Expect.that(e).toContain("UNIQUE")
    db.close
  }
}

Test.run()
