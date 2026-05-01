// lib/catalog.wren — package catalog backed by an in-memory SQLite
// table populated from the GitHub-hosted `index.toml`.
//
// Why this shape:
//   * GitHub raw is CDN-cached and free for read-heavy workloads;
//     we don't burden Supabase with one query per landing-page hit.
//   * Loading the rows into SQLite once means search + category
//     filter + most-recent ordering are real SQL — no Wren-side
//     List filtering at request time.
//   * Refreshing every 5 minutes is more than enough — the
//     `index.toml` mirror is rebuilt every 6 hours by
//     `sync-index.yml`, so the page is always fresher than the
//     source.

// `@hatch:sqlite` carries a native plugin (`libwlift_sqlite.dylib`)
// that needs the runtime's plugin-loading machinery — relative
// imports skip it, so we use the registered name. `@hatch:toml`
// + `@hatch:proc` are pure-Wren so either name shape would work;
// using the registry name keeps imports uniform.
import "@hatch:toml"   for Toml
import "@hatch:sqlite" for Database
import "@hatch:proc"   for Proc

/// Public API:
///
///   Catalog.boot()                    // open db + initial fetch
///   Catalog.refresh()                 // rebuild table (single shot)
///   Catalog.count                     // distinct-name count
///   Catalog.recent(limit)             // most recent rows
///   Catalog.search(q, cat, limit)     // SQL search + filter
///   Catalog.byCategory                // {"net": N, "data": N, ...}
class Catalog {
  static INDEX_URL_ { "https://raw.githubusercontent.com/wrenlift/hatch/main/index.toml" }

  /// Color tokens picked to match the design's category chips —
  /// kept on the data layer so the templates stay dumb (a card
  /// just renders `p.catColor`).
  static CAT_COLORS_ { {
    "net":  "#B8D4E3",
    "data": "#F4C24A",
    "sys":  "#8FAE6A",
    "dev":  "#D97A2B"
  } }

  static CAT_LABELS_ { {
    "net":  "networking",
    "data": "data",
    "sys":  "system",
    "dev":  "dev tools"
  } }

  // Module-level state. We open the db once on boot and keep the
  // handle for the life of the process — sqlite-wasm-rs' memory
  // VFS can't survive a close+reopen across our refresh fiber.
  static db { __db }
  static db=(value) { __db = value }

  /// Open the in-memory db, build the schema, fetch + populate.
  /// Aborts on first-fetch failure — no point booting a packages
  /// page with no packages.
  static boot() {
    Catalog.db = Database.openMemory()
    Catalog.createSchema_()
    Catalog.refresh()
  }

  static createSchema_() {
    Catalog.db.execute(
      "CREATE TABLE packages (" +
      "  name        TEXT NOT NULL," +
      "  version     TEXT NOT NULL," +
      "  git         TEXT," +
      "  description TEXT," +
      "  cat         TEXT NOT NULL," +
      "  created_at  TEXT NOT NULL," +
      "  PRIMARY KEY (name, version)" +
      ")"
    )
    Catalog.db.execute("CREATE INDEX idx_packages_name    ON packages(name)")
    Catalog.db.execute("CREATE INDEX idx_packages_cat     ON packages(cat)")
    Catalog.db.execute("CREATE INDEX idx_packages_created ON packages(created_at DESC)")
  }

  /// One-shot refresh. Wipes the table and bulk-loads from
  /// index.toml inside a transaction so partial-fetch failures
  /// can't leave the page with a half-empty grid.
  static refresh() {
    var rows = Catalog.fetchAndParse_()
    Catalog.db.transaction {
      Catalog.db.execute("DELETE FROM packages")
      for (row in rows) {
        Catalog.db.execute(
          "INSERT INTO packages (name, version, git, description, cat, created_at) " +
          "VALUES (?, ?, ?, ?, ?, ?)",
          [row["name"], row["version"], row["git"], row["description"],
           row["cat"], row["created_at"]]
        )
      }
    }
  }

  /// Curl out to GitHub raw + parse. We use @hatch:proc rather
  /// than @hatch:http because @hatch:web ships @hatch:json@0.1.2
  /// while @hatch:http ships @hatch:json@0.1.0 — having both as
  /// transitives makes the bundler reject the encode.
  static fetchAndParse_() {
    var r = Proc.exec(["curl", "-fsSL", Catalog.INDEX_URL_, "--max-time", "10"])
    if (!r.ok) Fiber.abort("Catalog.refresh: curl failed: %(r.stderr)")
    var doc = Toml.parse(r.stdout)
    var packages = doc["packages"]
    if (!(packages is Map)) Fiber.abort("Catalog.refresh: unexpected index.toml shape")
    var out = []
    for (key in packages.keys) {
      var row = packages[key]
      var name = row["name"]
      var description = row.containsKey("description") ? row["description"] : ""
      out.add({
        "name":        name,
        "version":     row["version"],
        "git":         row.containsKey("git") ? row["git"] : "",
        "description": description,
        "cat":         Catalog.categorize_(name, description),
        "created_at":  row.containsKey("created_at") ? row["created_at"] : ""
      })
    }
    return out
  }

  /// Heuristic on package name + description. Errs on the side of
  /// "dev" (the catch-all) so unknown names don't all land under
  /// "data" or "system" arbitrarily. Wren's String has no
  /// `lowercase` method; we ASCII-lowercase by hand since every
  /// package name we care about is ASCII anyway.
  static categorize_(name, desc) {
    var s = Catalog.lower_(name + " " + (desc == null ? "" : desc))

    // Networking — talks to the wire.
    var netKeywords = ["http", "websocket", "socket", "tcp", "udp", "dns", "url", "https"]
    for (kw in netKeywords) if (s.contains(kw)) return "net"

    // Data — encoding, storage, structure.
    var dataKeywords = ["json", "yaml", "toml", "csv", "sqlite", "regex", "hash",
                         "crypto", "uuid", "buffers", "tar", "zip", "image"]
    for (kw in dataKeywords) if (s.contains(kw)) return "data"

    // System — fs, processes, time, OS-ish.
    var sysKeywords = ["fs", "io", "os", "path", "proc", "time", "datetime",
                        "log", "fmt", "events", "audio", "physics", "gpu",
                        "window", "game", "assets", "random"]
    for (kw in sysKeywords) if (s.contains(kw)) return "sys"

    return "dev"
  }

  /// ASCII-lowercase a string. Maps `A`..`Z` (0x41..0x5A) to
  /// `a`..`z` (0x61..0x7A). Non-ASCII bytes pass through.
  static lower_(s) {
    var out = ""
    for (i in 0...s.count) {
      var c = s.bytes[i]
      if (c >= 65 && c <= 90) c = c + 32
      out = out + String.fromByte(c)
    }
    return out
  }

  // -- Public read API --

  /// Distinct-name count out of the catalog.
  static count {
    var row = Catalog.db.queryRow("SELECT COUNT(DISTINCT name) AS n FROM packages")
    return row["n"]
  }

  /// `{net: N, data: N, sys: N, dev: N}` — distinct-name counts per
  /// category, used to populate the filter chip badges.
  static byCategory {
    var rows = Catalog.db.query(
      "SELECT cat, COUNT(DISTINCT name) AS n FROM packages GROUP BY cat"
    )
    var out = { "net": 0, "data": 0, "sys": 0, "dev": 0 }
    for (row in rows) out[row["cat"]] = row["n"]
    return out
  }

  /// Most recent version of each package, newest first.
  static recent(limit) {
    var rows = Catalog.db.query(
      "SELECT * FROM packages WHERE (name, created_at) IN " +
      "  (SELECT name, MAX(created_at) FROM packages GROUP BY name) " +
      "ORDER BY created_at DESC LIMIT ?",
      [limit]
    )
    return Catalog.decorate_(rows)
  }

  /// Free-text search + optional category filter. `q` and `cat`
  /// can be null/empty — empty matches everything in that axis.
  static search(query, cat, limit) {
    var hasQ   = query != null && query != ""
    var hasCat = cat   != null && cat   != "" && cat != "all"

    var sql =
      "SELECT * FROM packages WHERE (name, created_at) IN " +
      "  (SELECT name, MAX(created_at) FROM packages GROUP BY name)"
    var params = []

    if (hasQ) {
      sql = sql + " AND (LOWER(name) LIKE ? OR LOWER(description) LIKE ?)"
      var pat = "%" + Catalog.lower_(query) + "%"
      params.add(pat)
      params.add(pat)
    }

    if (hasCat) {
      sql = sql + " AND cat = ?"
      params.add(cat)
    }

    sql = sql + " ORDER BY created_at DESC LIMIT ?"
    params.add(limit)

    return Catalog.decorate_(Catalog.db.query(sql, params))
  }

  /// Attach view-helper fields that the template can splice in
  /// without further computation. Keeps the renderer dumb.
  static decorate_(rows) {
    var colors = Catalog.CAT_COLORS_
    var labels = Catalog.CAT_LABELS_
    var out = []
    for (row in rows) {
      var cat = row["cat"]
      var copy = {}
      for (k in row.keys) copy[k] = row[k]
      copy["catColor"]    = colors.containsKey(cat) ? colors[cat] : "#EFDDA8"
      copy["catLabel"]    = labels.containsKey(cat) ? labels[cat] : cat
      copy["relativeAge"] = Catalog.shortDate_(row["created_at"])
      out.add(copy)
    }
    return out
  }

  /// "2026-04-30T19:31:51.372215+00:00" -> "Apr 30, 2026".
  /// Cheap to compute — we re-do this per response rather than
  /// caching since the catalog is small.
  static shortDate_(iso) {
    if (iso == null || iso == "") return ""
    // ISO 8601 always starts with YYYY-MM-DDT...
    var m = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    var year  = Num.fromString(iso[0..3])
    var month = Num.fromString(iso[5..6])
    var day   = Num.fromString(iso[8..9])
    if (year == null || month == null || day == null) return iso
    if (month < 1 || month > 12) return iso
    return "%(m[month - 1]) %(day), %(year)"
  }
}
