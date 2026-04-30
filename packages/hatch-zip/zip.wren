// @hatch:zip — in-memory ZIP read/write.
//
//   import "@hatch:zip" for Zip
//
//   // Inspect
//   Zip.entries(bytes)         // List<String> of entry names
//   Zip.info(bytes)            // List<Map> — name/size/compressedSize/isDir/method
//
//   // Read
//   Zip.read(bytes, "a.txt")   // List<Num> bytes of that entry, or null
//   Zip.readAll(bytes)         // Map<String name → List<Num> bytes> (skips dirs)
//
//   // Write
//   var archive = Zip.write({
//     "hello.txt":  "Hello, world!",
//     "notes.json": "[1, 2, 3]",
//   })
//   // archive is List<Num> — pair with `FS.writeBytes(path, archive)`.
//
// Archives are always byte lists (List<Num in 0..=255>). This
// keeps the API orthogonal to how you got them — off disk via
// @hatch:fs, over the wire via @hatch:http, generated in memory,
// whatever.
//
// Write entries take either a Map {name → bytes} or a List of
// [name, bytes] pairs. The List form preserves caller order, the
// Map form is convenient. Values can be Strings (UTF-8) or byte
// lists.
//
// Compression method defaults to "deflate". Also accepts "store"
// (no compression) and "zstd" (smaller + slower). Mismatched
// entries across methods are fine — each call to `Zip.write` uses
// a single method for the whole archive; mix methods by chaining
// multiple writes if you really need it.
//
// Backed by the Rust `zip` crate (deflate + zstd enabled).

import "zip" for ZipCore

class Zip {
  /// List entry names, in archive order.
  static entries(bytes) {
    validateBytes_(bytes, "Zip.entries")
    return ZipCore.entries(bytes)
  }

  /// List of Maps, one per entry, with:
  ///   name            → String
  ///   size            → Num   (uncompressed byte length)
  ///   compressedSize  → Num
  ///   isDir           → Bool
  ///   method          → String  ("store" | "deflate" | "zstd" | "other")
  static info(bytes) {
    validateBytes_(bytes, "Zip.info")
    return ZipCore.info(bytes)
  }

  /// Read a single named entry. Returns the uncompressed bytes as
  /// a List<Num>, or `null` if no entry has that name. Aborts on
  /// a malformed archive.
  static read(bytes, name) {
    validateBytes_(bytes, "Zip.read")
    if (!(name is String)) Fiber.abort("Zip.read: name must be a string")
    return ZipCore.read(bytes, name)
  }

  /// Read every file entry into a Map<name → bytes>. Directory
  /// entries are dropped — they carry no payload. Order within
  /// the returned Map follows insertion order (archive order).
  static readAll(bytes) {
    validateBytes_(bytes, "Zip.readAll")
    return ZipCore.readAll(bytes)
  }

  /// Write entries using the default "deflate" compression.
  static write(entries) { write(entries, "deflate") }

  /// Write entries with an explicit compression method. Pass
  /// "store", "deflate", or "zstd". Returns the full archive as
  /// a List<Num> ready to hand to `FS.writeBytes` or an HTTP
  /// response body.
  static write(entries, method) {
    if (!(entries is Map) && !(entries is List)) {
      Fiber.abort("Zip.write: entries must be a Map or List of [name, bytes] pairs")
    }
    if (!(method is String)) Fiber.abort("Zip.write: method must be a string")
    return ZipCore.write(entries, method)
  }

  static validateBytes_(b, label) {
    if (!((b is List) || (b is ByteArray))) {
      Fiber.abort("%(label): archive must be a list of bytes")
    }
  }
}
