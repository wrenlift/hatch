Read and write ZIP archives entirely in memory. One class — `Zip` — covering the four operations you actually want: list entries, read a named entry, read every entry into a map, write a fresh archive. Backed by the Rust `zip` crate with `deflate` and `zstd` enabled.

## Overview

Archives flow through the API as `List<Num>` (or `ByteArray`) — bytes in, bytes out. That keeps the package orthogonal to how the archive arrived: load it from disk via `@hatch:fs`, fetch it over the wire via `@hatch:http`, generate it in memory, all the same shape.

```wren
import "@hatch:zip" for Zip

System.print(Zip.entries(bytes))        // ["hello.txt", "data/notes.json"]

for (e in Zip.info(bytes)) {
  System.print("%(e["name"])  %(e["size"])b  %(e["method"])")
}

var hello = Zip.read(bytes, "hello.txt")     // List<Num> or null
var all   = Zip.readAll(bytes)                // Map<name, bytes>
```

`Zip.info` returns the per-entry metadata you'd want before deciding to extract — name, uncompressed `size`, `compressedSize`, `isDir`, and `method` (`"store"` / `"deflate"` / `"zstd"` / `"other"`).

## Writing archives

`Zip.write` accepts either a `Map<name, bytes>` or a `List<[name, bytes]>` — the list form preserves caller order, the map form is convenient. Values can be `String` (UTF-8) or byte lists.

```wren
var archive = Zip.write({
  "hello.txt":  "Hello, world!",
  "notes.json": "[1, 2, 3]"
})

Fs.writeBytes("out.zip", archive)
```

The default compression method is `deflate`. Pass `"store"` for no compression (fast, large) or `"zstd"` for smaller-and-slower output.

```wren
var compressed = Zip.write(entries, "zstd")
```

Each `Zip.write` call uses a single method for the whole archive. Mix methods by chaining several writes if you really need it (the resulting archive is still valid as long as every reader you target supports the methods you used).

> **Note — read errors are fiber aborts**
> Malformed input aborts with the underlying crate's error message. Wrap in `Fiber.new { Zip.read(bytes, name) }.try()` for fallible parsing. Missing entries return `null` rather than abort, so a clean "is this name present?" check is `Zip.read(bytes, name) != null`.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Native only — `#!wasm` builds need a separate WASM-compiled zip bridge that hasn't shipped yet. Pair with `@hatch:fs` for archive I/O, `@hatch:http` for archive uploads / downloads.
