TCP listeners and connections plus UDP datagram sockets. `TcpListener` for servers, `TcpStream` for clients (and accepted server-side connections), `UdpSocket` for datagram sends and receives. Each operation has a blocking variant and a `try*` non-blocking sibling that returns `null` when nothing is ready — pair the latter with `Fiber.yield()` for cooperative servers without OS threads.

## Overview

Bind, accept, read, write. The blocking shape works for simple scripts; the non-blocking shape composes with `@hatch:events`'s `Scheduler` for fiber-cooperative IO.

```wren
import "@hatch:socket" for TcpListener, TcpStream, UdpSocket

// Server
var server = TcpListener.bind("127.0.0.1:0")
System.print(server.address)          // 127.0.0.1:<picked-port>

var conn = server.accept              // blocks
conn.write("hello\n")
conn.close
server.close

// Client
var client = TcpStream.connect("127.0.0.1:8080")
client.write("GET / HTTP/1.0\r\n\r\n")
var chunk = client.read(4096)         // List<Num>, [] on EOF
client.close

// UDP
var a = UdpSocket.bind("127.0.0.1:0")
var b = UdpSocket.bind("127.0.0.1:0")
a.sendTo("ping", b.address)
var msg = b.recvFrom(1024)            // [bytes, fromAddr]
```

Bind to port `0` to let the OS pick a free port; read it back from `listener.address` / `socket.address`.

## Cooperative IO

The `try*` variants return `null` when no data is ready. Drop them into a fiber loop and yield between polls:

```wren
import "@hatch:events" for Scheduler

var serve = Fiber.new {
  var server = TcpListener.bind("0.0.0.0:8080")
  while (true) {
    var conn = server.tryAccept
    if (conn == null) {
      Fiber.yield()
      continue
    }
    handle(conn)
  }
}

Scheduler.runAll([serve])
```

Reads against `tryRead(n)` follow the same shape — `null` means "nothing yet, yield and come back."

> **Note — TCP byte conventions match the stdlib**
> Writes accept a `String` (UTF-8 bytes) or a `List<Num>` / `ByteArray` in `0..=255`. Reads always return `List<Num>`. An empty list signals EOF on TCP; UDP `recvFrom` blocks until a datagram arrives (or returns `null` from `tryRecvFrom` when nothing's pending).

> **Warning — TLS lives elsewhere**
> This package speaks raw sockets only. For TLS termination, use `@hatch:http`'s client (which handles TLS for outbound HTTP) or wait for the server-side TLS bridge that depends on `@hatch:io`'s ALPN surface stabilising.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Native only — `#!wasm` builds use `@hatch:web`'s WebSocket bridge for browser networking. Backed by `std::net`, so no async runtime leaks into Wren code.
