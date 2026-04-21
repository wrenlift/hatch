import "./socket"      for TcpListener, TcpStream, UdpSocket
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- Shared helpers --------------------------------------------

// Bounded-retry accept — Wren's test harness runs everything in
// a single thread, so a pure blocking `accept` would hang if the
// connect happened after. Each retry hands control back to the
// OS. In practice the connect's already in the accept queue by
// the time we get here, so the first poll hits.
var pollAccept = Fn.new { |server|
  var tries = 0
  var conn = null
  while (conn == null && tries < 100) {
    conn = server.tryAccept
    tries = tries + 1
  }
  return conn
}

// Read exactly `n` bytes off a stream, retrying through `tryRead`
// until `n` bytes accumulate. Returns a List<Num>. Caps the
// retry count so a lost peer doesn't hang the test forever.
var pollRead = Fn.new { |conn, n|
  var collected = []
  var tries = 0
  while (collected.count < n && tries < 200) {
    var chunk = conn.tryRead(n - collected.count)
    if (chunk != null) {
      var i = 0
      while (i < chunk.count) {
        collected.add(chunk[i])
        i = i + 1
      }
    }
    tries = tries + 1
  }
  return collected
}

// --- TCP --------------------------------------------------------

Test.describe("TcpListener") {
  Test.it("binds to an ephemeral port and reports its address") {
    var server = TcpListener.bind("127.0.0.1:0")
    Expect.that(server.address).toContain("127.0.0.1:")
    // tryAccept with no client pending returns null right away.
    Expect.that(server.tryAccept).toBeNull()
    server.close
  }

  Test.it("bad host aborts") {
    var e = Fiber.new { TcpListener.bind("not a real addr") }.try()
    Expect.that(e).toContain("Tcp.listen")
  }

  Test.it("non-string addr aborts") {
    var e = Fiber.new { TcpListener.bind(42) }.try()
    Expect.that(e).toContain("string")
  }
}

Test.describe("TcpStream round-trip") {
  Test.it("client → server write") {
    var server = TcpListener.bind("127.0.0.1:0")
    var addr = server.address
    var client = TcpStream.connect(addr)
    var conn = pollAccept.call(server)
    Expect.that(conn).not.toBeNull()

    client.write("hello")
    var bytes = pollRead.call(conn, 5)
    Expect.that(bytes.count).toBe(5)
    Expect.that(bytes[0]).toBe(0x68) // h
    Expect.that(bytes[4]).toBe(0x6F) // o

    client.close
    conn.close
    server.close
  }

  Test.it("server → client write (binary)") {
    var server = TcpListener.bind("127.0.0.1:0")
    var client = TcpStream.connect(server.address)
    var conn = pollAccept.call(server)

    conn.write([0, 1, 2, 3, 255])
    var bytes = pollRead.call(client, 5)
    Expect.that(bytes.count).toBe(5)
    Expect.that(bytes[0]).toBe(0)
    Expect.that(bytes[4]).toBe(255)

    client.close
    conn.close
    server.close
  }

  Test.it("tryRead returns null when no data pending") {
    var server = TcpListener.bind("127.0.0.1:0")
    var client = TcpStream.connect(server.address)
    var conn = pollAccept.call(server)

    Expect.that(conn.tryRead(64)).toBeNull()
    client.close
    conn.close
    server.close
  }

  Test.it("peer close → empty list on read") {
    var server = TcpListener.bind("127.0.0.1:0")
    var client = TcpStream.connect(server.address)
    var conn = pollAccept.call(server)

    client.close  // Shuts down client's write half → server sees EOF.

    // Poll a few times to let the FIN propagate; accept either
    // empty-list-EOF or null (no data yet) as "not a surprise".
    var tries = 0
    var eof = false
    while (tries < 100 && !eof) {
      var chunk = conn.tryRead(64)
      if (chunk != null && chunk.count == 0) eof = true
      tries = tries + 1
    }
    Expect.that(eof).toBe(true)

    conn.close
    server.close
  }

  Test.it("peerAddr + localAddr report the wired endpoints") {
    var server = TcpListener.bind("127.0.0.1:0")
    var client = TcpStream.connect(server.address)
    var conn = pollAccept.call(server)

    Expect.that(client.peerAddr).toBe(server.address)
    Expect.that(conn.peerAddr).toBe(client.localAddr)

    client.close
    conn.close
    server.close
  }
}

Test.describe("TcpStream validation") {
  Test.it("unreachable host aborts") {
    // Reserved TEST-NET-1 address — guaranteed to be unroutable.
    // Short timeout so the test doesn't hang on slow networks.
    var e = Fiber.new {
      TcpStream.connect("192.0.2.1:12345", 100)
    }.try()
    Expect.that(e).toContain("Tcp.connect")
  }
}

// --- UDP --------------------------------------------------------

Test.describe("UdpSocket round-trip") {
  Test.it("sendTo + recvFrom round-trip") {
    var a = UdpSocket.bind("127.0.0.1:0")
    var b = UdpSocket.bind("127.0.0.1:0")

    a.sendTo("hello", b.address)
    // Poll because UDP delivery is async at the kernel level —
    // recvFrom is blocking, but we pair with a short timeout-ish
    // loop so we can still exit if the packet got dropped on a
    // particularly pathological CI runner.
    var pair = null
    var tries = 0
    while (pair == null && tries < 200) {
      pair = b.tryRecvFrom(1024)
      tries = tries + 1
    }
    Expect.that(pair).not.toBeNull()
    Expect.that(pair[0].count).toBe(5)
    Expect.that(pair[0][0]).toBe(0x68) // h
    Expect.that(pair[1]).toBe(a.address)

    a.close
    b.close
  }

  Test.it("binary payload round-trip") {
    var a = UdpSocket.bind("127.0.0.1:0")
    var b = UdpSocket.bind("127.0.0.1:0")
    var payload = [0xDE, 0xAD, 0xBE, 0xEF]
    a.sendTo(payload, b.address)

    var pair = null
    var tries = 0
    while (pair == null && tries < 200) {
      pair = b.tryRecvFrom(1024)
      tries = tries + 1
    }
    Expect.that(pair[0].count).toBe(4)
    Expect.that(pair[0][0]).toBe(0xDE)
    Expect.that(pair[0][3]).toBe(0xEF)

    a.close
    b.close
  }

  Test.it("tryRecvFrom with no pending datagrams returns null") {
    var s = UdpSocket.bind("127.0.0.1:0")
    Expect.that(s.tryRecvFrom(1024)).toBeNull()
    s.close
  }

  Test.it("address reports bound port") {
    var s = UdpSocket.bind("127.0.0.1:0")
    Expect.that(s.address).toContain("127.0.0.1:")
    s.close
  }
}

Test.run()
