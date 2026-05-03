Byte buffers and stream interfaces. `Buffer` wraps a mutable byte sequence with ergonomic slicing and string round-tripping. `Reader` and `Writer` are abstract interfaces with line-oriented and Buffer-shaped conveniences over a tiny `readRaw_` / `writeRaw_` substrate. Bundled concrete types (`BufferReader`, `BufferWriter`, `StringReader`) cover the common in-memory cases; subclass for files, sockets, or pipes.

## Overview

Use `Buffer` when you would otherwise reach for `List<Num>` and quickly miss `slice`, `toString`, `indexOf`, and a clean string round-trip. Use the stream interfaces when the data lives somewhere else and you want a uniform shape over it.

```wren
import "@hatch:io" for Buffer, BufferReader, BufferWriter

var b = Buffer.fromString("hello world")
System.print(b.count)             // 11
System.print(b.byteAt(0))         // 104
System.print(b.slice(0, 5).toString) // "hello"
System.print(b.indexOf(0x20))     // 5
```

`Buffer.fromBytes(list)` copies the input so later mutations on the original do not leak through. `buffer.toList` drops back to a `List<Num>` for module boundaries (`Hash.sha256Bytes` and friends).

## Streams

Subclass `Reader` and provide a single `readRaw_(maxBytes)` method that returns up to `maxBytes` bytes as a `List<Num>`, or `null` at EOF. The base class layers `read(n)`, `readAll`, `readLine`, and `readToString` on top.

```wren
import "@hatch:io" for Reader, StringReader

var r = StringReader.new("first\nsecond\nthird")
while (true) {
  var line = r.readLine
  if (line == null) break
  System.print(line)
}
```

`readLine` buffers internally until it sees `\n` or EOF, then returns the line as a `String` with the trailing `\n` (and any preceding `\r`) stripped. Byte-oriented IO stays explicit so non-UTF-8 data does not surprise callers.

For writers, override `writeRaw_(bytes)`. `Writer.write(data)` accepts a `Buffer`, `String`, or `List<Num>` uniformly. `close` is a no-op unless the subclass needs it (for example, closing a child process's stdin).

> **Tip: duck typing wins**
> The interfaces are not strictly nominal. Anything that exposes `read` / `write` / `close` will satisfy a downstream consumer. The `Reader` / `Writer` base classes are there to save the boilerplate, not to gate-keep.

## Compatibility

Wren 0.4 and WrenLift runtime 0.1 or newer. Built on the runtime's `io` module (UTF-8 byte conversions). Pure-Wren elsewhere; works on every supported target.
