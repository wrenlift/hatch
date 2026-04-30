// @hatch:io — byte buffers and stream interfaces.
//
//   import "@hatch:io" for Buffer, Reader, Writer, BufferReader, BufferWriter, StringReader
//
// ## Buffer
//
// A mutable byte sequence. Wren's built-in `List<Num>` holds
// bytes fine, but lacks ergonomic slicing / string round-tripping.
// `Buffer` wraps one and adds conveniences:
//
//   var b = Buffer.fromString("hello")
//   b.count                // 5
//   b.byteAt(0)            // 104 (h)
//   b.toString             // "hello"
//   b.append(" world")
//   b.slice(0, 5).toString // "hello"
//   b.indexOf(0x20)        // 5 — the space
//
// `Buffer.fromBytes(list)` and `buffer.toList` let you drop back
// to a plain `List<Num>` at module boundaries (e.g. to feed
// `Hash.sha256Bytes`).
//
// ## Streams
//
// `Reader` and `Writer` are abstract interfaces. Subclass them
// by providing `readRaw_(maxBytes) → List<Num> or null` (null =
// EOF) for readers, or `writeRaw_(bytes) → null` for writers;
// the base class supplies line-oriented, string, and buffer
// conveniences.
//
//   class MyReader is Reader {
//     construct new(src) { _src = src; _pos = 0 }
//     readRaw_(maxBytes) {
//       if (_pos >= _src.count) return null
//       var end = _pos + maxBytes
//       if (end > _src.count) end = _src.count
//       var chunk = _src[_pos..(end - 1)]
//       _pos = end
//       return chunk
//     }
//   }
//
// Bundled concrete types:
//
//   BufferReader(buffer)          // read an in-memory Buffer
//   BufferWriter()                // append into a Buffer
//   StringReader(str)             // treat a String as a Reader
//
// The design is explicit: `Reader.read(n)` returns up to `n`
// bytes as a Buffer (never longer; possibly shorter; empty at
// EOF). `Reader.readAll` loops until EOF. `Reader.readLine`
// buffers internally until it sees `\n` or EOF, then returns the
// line as a String (trailing `\n` and any preceding `\r`
// stripped). Byte-oriented IO stays explicit to avoid surprises
// with non-UTF-8 data.
//
// Writers are simpler: `Writer.write(data)` accepts a Buffer,
// String, or `List<Num>`. `Writer.close` is a no-op unless the
// concrete subclass needs it (e.g. `ProcessWriter` closes stdin).

import "io" for IoCore

// --- Buffer ------------------------------------------------------------------

class Buffer {
  construct new() {
    _bytes = []
  }

  // Private constructor that adopts a list without copying. Keep
  // it internal — callers should go through `fromBytes` if they
  // have a list they want wrapped.
  construct new_(bytes) {
    _bytes = bytes
  }

  static ofSize(n) {
    if (!(n is Num) || n < 0 || !n.isInteger) {
      Fiber.abort("Buffer.ofSize: n must be a non-negative integer")
    }
    var bs = []
    var i = 0
    while (i < n) {
      bs.add(0)
      i = i + 1
    }
    return Buffer.new_(bs)
  }

  static fromString(s) {
    if (!(s is String)) Fiber.abort("Buffer.fromString: expected a string")
    return Buffer.new_(IoCore.stringToBytes(s))
  }

  /// Copies the input list so mutations on the original don't
  /// leak through. If you want to share the list, construct via
  /// the returned Buffer and mutate through it.
  static fromBytes(list) {
    if (!(list is List)) Fiber.abort("Buffer.fromBytes: expected a list")
    var bs = []
    var i = 0
    while (i < list.count) {
      var b = list[i]
      if (!(b is Num) || b < 0 || b > 255 || !b.isInteger) {
        Fiber.abort("Buffer.fromBytes: bytes must be integers in 0..=255")
      }
      bs.add(b)
      i = i + 1
    }
    return Buffer.new_(bs)
  }

  count    { _bytes.count }
  isEmpty  { _bytes.count == 0 }

  /// Mutable view of the underlying list. Mutating this is
  /// equivalent to mutating the buffer; appending via `.add` won't
  /// surprise the Buffer because the Buffer doesn't cache count.
  /// Use sparingly; `toList` if you want a copy.
  bytes { _bytes }

  byteAt(i) {
    if (!(i is Num) || !i.isInteger) {
      Fiber.abort("Buffer.byteAt: index must be an integer")
    }
    var n = i < 0 ? i + _bytes.count : i
    if (n < 0 || n >= _bytes.count) Fiber.abort("Buffer.byteAt: index out of range")
    return _bytes[n]
  }

  setByteAt(i, value) {
    if (!(i is Num) || !i.isInteger) {
      Fiber.abort("Buffer.setByteAt: index must be an integer")
    }
    if (!(value is Num) || value < 0 || value > 255 || !value.isInteger) {
      Fiber.abort("Buffer.setByteAt: value must be an integer in 0..=255")
    }
    var n = i < 0 ? i + _bytes.count : i
    if (n < 0 || n >= _bytes.count) Fiber.abort("Buffer.setByteAt: index out of range")
    _bytes[n] = value
  }

  append(data) {
    if (data is Buffer) {
      var i = 0
      while (i < data.count) {
        _bytes.add(data.bytes[i])
        i = i + 1
      }
    } else if (data is String) {
      var bs = IoCore.stringToBytes(data)
      var i = 0
      while (i < bs.count) {
        _bytes.add(bs[i])
        i = i + 1
      }
    } else if (data is List) {
      var i = 0
      while (i < data.count) {
        var b = data[i]
        if (!(b is Num) || b < 0 || b > 255 || !b.isInteger) {
          Fiber.abort("Buffer.append: list entries must be integers in 0..=255")
        }
        _bytes.add(b)
        i = i + 1
      }
    } else {
      Fiber.abort("Buffer.append: expected a Buffer, String, or List of bytes")
    }
    return this
  }

  clear { _bytes.clear() }

  slice(start) { slice(start, _bytes.count) }
  slice(start, end) {
    var s = start < 0 ? start + _bytes.count : start
    var e = end   < 0 ? end   + _bytes.count : end
    if (s < 0 || e > _bytes.count || s > e) Fiber.abort("Buffer.slice: range out of bounds")
    var out = []
    var i = s
    while (i < e) {
      out.add(_bytes[i])
      i = i + 1
    }
    return Buffer.new_(out)
  }

  /// UTF-8 decode. Invalid sequences become U+FFFD replacement
  /// characters. If you need strict decoding, validate yourself
  /// first.
  toString { IoCore.bytesToString(_bytes) }

  /// Copy the bytes into a fresh List<Num>.
  toList {
    var out = []
    var i = 0
    while (i < _bytes.count) {
      out.add(_bytes[i])
      i = i + 1
    }
    return out
  }

  indexOf(byte) {
    if (!(byte is Num)) Fiber.abort("Buffer.indexOf: expected a byte value")
    var i = 0
    while (i < _bytes.count) {
      if (_bytes[i] == byte) return i
      i = i + 1
    }
    return -1
  }

  startsWith(prefix) {
    var b = Buffer.coerce_(prefix, "Buffer.startsWith")
    if (b.count > _bytes.count) return false
    var i = 0
    while (i < b.count) {
      if (_bytes[i] != b.bytes[i]) return false
      i = i + 1
    }
    return true
  }

  endsWith(suffix) {
    var b = Buffer.coerce_(suffix, "Buffer.endsWith")
    if (b.count > _bytes.count) return false
    var off = _bytes.count - b.count
    var i = 0
    while (i < b.count) {
      if (_bytes[off + i] != b.bytes[i]) return false
      i = i + 1
    }
    return true
  }

  ==(other) {
    if (!(other is Buffer)) return false
    if (_bytes.count != other.count) return false
    var i = 0
    while (i < _bytes.count) {
      if (_bytes[i] != other.bytes[i]) return false
      i = i + 1
    }
    return true
  }

  !=(other) { !(this == other) }

  toString_debug { "Buffer(%(count) bytes)" }

  // Internal: coerce Buffer | String | List into a Buffer view
  // without copying when possible.
  static coerce_(data, label) {
    if (data is Buffer) return data
    if (data is String) return Buffer.fromString(data)
    if (data is List)   return Buffer.fromBytes(data)
    Fiber.abort("%(label): expected a Buffer, String, or List of bytes")
  }
}

// --- Reader ------------------------------------------------------------------

class Reader {
  construct new() {
    _lineBuf = []
    _closed = false
    _readFn = null
    _closeFn = null
  }

  /// Alternate constructor for callers outside this module. Cross-
  /// module field inheritance isn't fully supported today, so
  /// `Reader.withFn { ... }` is the portable way to build a
  /// Reader backed by your own producer without subclassing.
  static withFn(readFn) {
    var r = Reader.new()
    r.setReadFn_(readFn)
    return r
  }

  /// Fiber-cooperative constructor. `tryReadFn` returns one of:
  ///   * `null`               — EOF; no more bytes ever.
  ///   * `[]`                 — "nothing right now, try again."
  ///   * `List<Num>` (non-empty) — bytes.
  ///
  /// The wrapper spins on the try-read and calls `Fiber.yield()`
  /// on every "would block" result, so other fibers in the same
  /// VM can make progress while this one waits on IO.
  ///
  ///   var r = Reader.withTryFn {|max| ProcCore.tryReadStdoutBytes(pid, max) }
  ///   // Use inside a Fiber.new { ... } to actually get concurrency.
  static withTryFn(tryReadFn) {
    var r = Reader.new()
    r.setReadFn_ {|max|
      var out = null
      var done = false
      while (!done) {
        var result = tryReadFn.call(max)
        if (result == null) {
          done = true
        } else if (result.count > 0) {
          out = result
          done = true
        } else {
          // WouldBlock — let other fibers run.
          Fiber.yield()
        }
      }
      return out
    }
    return r
  }

  // Internal — used by `withFn` and subclasses that prefer a
  // callback over overriding `readRaw_`.
  setReadFn_(fn)  { _readFn = fn }
  setCloseFn_(fn) { _closeFn = fn }

  // Subclass override OR the callback set by `withFn`. Returns a
  // `List<Num>` of up to `max` bytes, or null at EOF.
  readRaw_(max) {
    if (_readFn == null) Fiber.abort("Reader: subclass must implement readRaw_ or use Reader.withFn")
    return _readFn.call(max)
  }

  isClosed { _closed }

  /// Close the underlying resource. Idempotent. Callbacks set via
  /// `setCloseFn_` run once; subclasses can override this method
  /// directly if they need something more elaborate.
  close {
    if (_closed) return
    _closed = true
    if (_closeFn != null) _closeFn.call()
  }

  /// Read up to `n` bytes. Returns a Buffer (possibly empty at
  /// EOF). Shorter than `n` is fine — you get what's currently
  /// available.
  read(n) {
    if (_closed) return Buffer.new()
    if (!(n is Num) || n < 0 || !n.isInteger) {
      Fiber.abort("Reader.read: n must be a non-negative integer")
    }
    if (n == 0) return Buffer.new()
    // Drain the line buffer first, if anything queued there.
    if (_lineBuf.count > 0) {
      var take = _lineBuf.count
      if (take > n) take = n
      var out = []
      var i = 0
      while (i < take) {
        out.add(_lineBuf[0])
        _lineBuf.removeAt(0)
        i = i + 1
      }
      return Buffer.new_(out)
    }
    var chunk = readRaw_(n)
    if (chunk == null) return Buffer.new()
    return Buffer.new_(chunk)
  }

  /// Read until EOF. Returns a Buffer.
  readAll {
    var out = Buffer.new()
    // Drain any queued line-buffer bytes first.
    if (_lineBuf.count > 0) {
      var i = 0
      while (i < _lineBuf.count) {
        out.bytes.add(_lineBuf[i])
        i = i + 1
      }
      _lineBuf.clear()
    }
    if (_closed) return out
    while (true) {
      var chunk = readRaw_(4096)
      if (chunk == null) break
      var i = 0
      while (i < chunk.count) {
        out.bytes.add(chunk[i])
        i = i + 1
      }
    }
    return out
  }

  /// Read a single line (up to and including `\n`, whichever
  /// comes first). Returns a String with the trailing `\n` and
  /// any preceding `\r` stripped. Returns null at EOF — distinct
  /// from an empty line (`""` from a bare `\n`).
  readLine {
    if (_closed && _lineBuf.count == 0) return null
    while (true) {
      var nlIndex = -1
      var i = 0
      while (i < _lineBuf.count && nlIndex == -1) {
        if (_lineBuf[i] == 10) nlIndex = i
        i = i + 1
      }
      if (nlIndex != -1) {
        var end = nlIndex
        // Strip a trailing \r.
        if (end > 0 && _lineBuf[end - 1] == 13) end = end - 1
        var out = []
        var j = 0
        while (j < end) {
          out.add(_lineBuf[j])
          j = j + 1
        }
        // Drop consumed bytes including the newline.
        var drop = nlIndex + 1
        j = 0
        while (j < drop) {
          _lineBuf.removeAt(0)
          j = j + 1
        }
        return IoCore.bytesToString(out)
      }
      // No newline yet — pull more bytes.
      var chunk = readRaw_(4096)
      if (chunk == null) {
        // EOF. If we have a partial line, emit it; otherwise
        // return null.
        if (_lineBuf.count == 0) return null
        var out = _lineBuf
        _lineBuf = []
        return IoCore.bytesToString(out)
      }
      var k = 0
      while (k < chunk.count) {
        _lineBuf.add(chunk[k])
        k = k + 1
      }
    }
  }

  /// Consume the rest of the stream as UTF-8. Convenience around
  /// `readAll.toString`.
  readString { readAll.toString }
}

// --- Writer ------------------------------------------------------------------

class Writer {
  construct new() {
    _closed = false
    _writeFn = null
    _closeFn = null
    _flushFn = null
  }

  /// Alternate constructor for cross-module consumers.
  ///   var w = Writer.withFn {|bytes| ... }
  static withFn(writeFn) {
    var w = Writer.new()
    w.setWriteFn_(writeFn)
    return w
  }

  setWriteFn_(fn) { _writeFn = fn }
  setCloseFn_(fn) { _closeFn = fn }
  setFlushFn_(fn) { _flushFn = fn }

  // Subclass override OR the callback set by `withFn`. Consumes a
  // `List<Num>` of bytes.
  writeRaw_(bytes) {
    if (_writeFn == null) Fiber.abort("Writer: subclass must implement writeRaw_ or use Writer.withFn")
    _writeFn.call(bytes)
  }

  isClosed { _closed }

  close {
    if (_closed) return
    _closed = true
    if (_closeFn != null) _closeFn.call()
  }

  flush {
    if (_flushFn != null) _flushFn.call()
  }

  write(data) {
    if (_closed) Fiber.abort("Writer: write on closed writer")
    var buf = Buffer.coerce_(data, "Writer.write")
    writeRaw_(buf.bytes)
  }

  writeLine(s) {
    write(s)
    write("\n")
  }
}

// --- Concrete readers / writers ---------------------------------------------

/// Reads bytes from an in-memory Buffer (or anything Buffer-like).
class BufferReader is Reader {
  construct new(source) {
    super()
    _buf = Buffer.coerce_(source, "BufferReader")
    _pos = 0
  }

  position { _pos }

  readRaw_(max) {
    if (_pos >= _buf.count) return null
    var end = _pos + max
    if (end > _buf.count) end = _buf.count
    var out = []
    var i = _pos
    while (i < end) {
      out.add(_buf.bytes[i])
      i = i + 1
    }
    _pos = end
    return out
  }
}

/// Writes bytes into an in-memory Buffer. Retrieve via `.buffer`.
class BufferWriter is Writer {
  construct new() {
    super()
    _buf = Buffer.new()
  }

  buffer { _buf }

  writeRaw_(bytes) {
    var i = 0
    while (i < bytes.count) {
      _buf.bytes.add(bytes[i])
      i = i + 1
    }
  }
}

/// Convenience alias: reads a String's UTF-8 bytes.
class StringReader is Reader {
  construct new(s) {
    super()
    if (!(s is String)) Fiber.abort("StringReader: expected a string")
    _buf = Buffer.fromString(s)
    _pos = 0
  }

  readRaw_(max) {
    if (_pos >= _buf.count) return null
    var end = _pos + max
    if (end > _buf.count) end = _buf.count
    var out = []
    var i = _pos
    while (i < end) {
      out.add(_buf.bytes[i])
      i = i + 1
    }
    _pos = end
    return out
  }
}
