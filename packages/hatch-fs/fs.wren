// @hatch:fs — filesystem I/O.
//
//   import "@hatch:fs" for Fs
//
//   Fs.readText(path)                  // string
//   Fs.writeText(path, contents)
//   Fs.readLines(path)                 // List<String>
//   Fs.writeLines(path, list)
//   Fs.readBytes(path)                 // List<Num>, 0..255
//   Fs.writeBytes(path, bytes)
//
//   Fs.exists(path) / Fs.isFile(path) / Fs.isDir(path)
//   Fs.size(path)                      // byte count
//   Fs.listDir(path)                   // sorted entry names
//   Fs.walk(path)                      // recursive list, relative
//
//   Fs.mkdir(path) / Fs.mkdirs(path)
//   Fs.remove(path)                    // single file / empty dir
//   Fs.removeTree(path)                // recursive
//   Fs.rename(from, to)
//
//   Fs.cwd / Fs.home / Fs.tmpDir
//
// All operations are synchronous and abort on failure — wrap in
// `Fiber.new { ... }.try()` to catch.
//
// Backed by the runtime `fs` module (Rust std::fs). Unix-ish
// paths; on Windows the native layer still works but callers
// should prefer forward slashes via `@hatch:path` until
// platform-aware path helpers land.

import "fs" for FS

class Fs {
  // -- Text ---------------------------------------------------------------

  static readText(path) { FS.readText(path) }
  static writeText(path, contents) { FS.writeText(path, contents) }

  // Lines: split on `\n`, drop the trailing empty element if the
  // file ends in a newline (so a file with content "a\nb\n" yields
  // `["a", "b"]`, not `["a", "b", ""]`).
  static readLines(path) {
    var text = FS.readText(path)
    if (text == "") return []
    var parts = text.split("\n")
    if (parts.count > 0 && parts[parts.count - 1] == "") {
      return parts[0...(parts.count - 1)]
    }
    return parts
  }

  // writeLines joins with `\n` and appends a final newline so the
  // file is a well-behaved text file in the POSIX sense.
  static writeLines(path, lines) {
    if (!(lines is List)) {
      Fiber.abort("Fs.writeLines: expected a list of strings")
    }
    var joined = lines.join("\n")
    if (lines.count > 0) joined = joined + "\n"
    FS.writeText(path, joined)
  }

  // -- Bytes --------------------------------------------------------------

  static readBytes(path) { FS.readBytes(path) }
  static writeBytes(path, bytes) { FS.writeBytes(path, bytes) }

  // -- Metadata -----------------------------------------------------------

  static exists(path) { FS.exists(path) }
  static isFile(path) { FS.isFile(path) }
  static isDir(path) { FS.isDir(path) }
  static size(path) { FS.size(path) }

  // -- Directory ops ------------------------------------------------------

  static listDir(path) { FS.listDir(path) }
  static mkdir(path) { FS.mkdir(path) }
  static mkdirs(path) { FS.mkdirs(path) }
  static remove(path) { FS.remove(path) }
  static removeTree(path) { FS.removeTree(path) }
  static rename(from, to) { FS.rename(from, to) }

  // walk(path) → flat list of path strings relative to `path`,
  // recursive, sorted per-level. Skips nothing — callers that want
  // to exclude (e.g.) `.git/` filter the returned list.
  static walk(path) {
    var results = []
    walkInto_(path, "", results)
    return results
  }

  static walkInto_(root, prefix, results) {
    var entries = FS.listDir(root)
    var i = 0
    while (i < entries.count) {
      var name = entries[i]
      i = i + 1
      var rel = prefix == "" ? name : prefix + "/" + name
      var full = root + "/" + name
      results.add(rel)
      if (FS.isDir(full)) walkInto_(full, rel, results)
    }
  }

  // -- Process paths ------------------------------------------------------

  static cwd { FS.cwd }
  static home { FS.home }
  static tmpDir { FS.tmpDir }
}
