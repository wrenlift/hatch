// @hatch:socket — TCP + UDP sockets.
//
//   import "@hatch:socket" for TcpListener, TcpStream, UdpSocket
//
//   // TCP server
//   var server = TcpListener.bind("127.0.0.1:0")
//   System.print(server.address)            // 127.0.0.1:<port>
//   var conn = server.accept                // blocking
//   conn.write("hello\n")
//   conn.close
//   server.close
//
//   // TCP client
//   var client = TcpStream.connect("127.0.0.1:8080")
//   client.write("GET /\r\n\r\n")
//   var chunk = client.read(4096)            // List<Num>, or []-EOF
//   client.close
//
//   // UDP
//   var a = UdpSocket.bind("127.0.0.1:0")
//   var b = UdpSocket.bind("127.0.0.1:0")
//   a.sendTo("ping", b.address)
//   var msg = b.recvFrom(1024)               // [bytes, fromAddr]
//
// Non-blocking variants — `tryAccept`, `tryRead`, `tryRecvFrom` —
// return `null` when nothing is ready, so callers can yield back
// to a fiber scheduler (e.g. @hatch:events) without needing OS
// threads. Pair `conn.tryRead(n)` with `Fiber.yield()` to write
// cooperative servers in pure Wren.
//
// Byte conventions match the rest of the stdlib: writes accept a
// String (UTF-8 bytes) or a List<Num in 0..=255>; reads always
// hand back List<Num>. An empty list means EOF on TCP.
//
// Backed by `std::net` (blocking sockets with per-call non-block
// toggle) — no external runtime, no async runtime leaking into
// Wren code.

import "socket" for SocketCore

class TcpListener {
  /// Bind + listen on an address string ("host:port"). The host
  /// half accepts IPv4, IPv6, or a DNS name. Returns a listener.
  /// Pass port 0 to let the OS pick a free port — read it back
  /// from `.address`.
  static bind(addr) {
    if (!(addr is String)) Fiber.abort("TcpListener.bind: addr must be a string")
    return TcpListener.new_(SocketCore.tcpListen(addr))
  }

  construct new_(id) {
    _id = id
  }

  /// Block until a peer connects, then return a `TcpStream`.
  accept {
    return TcpStream.fromId_(SocketCore.tcpAccept(_id))
  }

  /// Non-blocking accept. Returns a `TcpStream` or `null` if no
  /// peer is pending — pair with `Fiber.yield()` for cooperative
  /// servers.
  tryAccept {
    var sid = SocketCore.tcpTryAccept(_id)
    if (sid == null) return null
    return TcpStream.fromId_(sid)
  }

  /// String form of the bound local address, including the port
  /// the OS picked when bound to port 0.
  address { SocketCore.tcpListenerLocalAddr(_id) }

  /// Free the underlying listener. Already-accepted streams keep
  /// working independently.
  close {
    SocketCore.tcpCloseListener(_id)
    return null
  }

  id_ { _id }
}

class TcpStream {
  /// Connect to a peer by "host:port" string. Blocks until the
  /// connection completes or `timeoutMs` elapses. Pass null to
  /// use the OS default timeout.
  static connect(addr)            { connect(addr, null) }
  static connect(addr, timeoutMs) {
    if (!(addr is String)) Fiber.abort("TcpStream.connect: addr must be a string")
    return TcpStream.fromId_(SocketCore.tcpConnect(addr, timeoutMs))
  }

  // Internal factory — listeners hand back raw ids after accept,
  // this wraps them in a TcpStream without re-entering the OS.
  static fromId_(id) {
    return TcpStream.new_(id)
  }

  construct new_(id) {
    _id = id
  }

  /// Block until up to `max` bytes arrive. Returns a List<Num>.
  /// An empty list signals EOF (peer closed their write half);
  /// callers distinguish EOF from "no data right now" because
  /// this form always blocks until *something* happens.
  read(max) { SocketCore.tcpRead(_id, max) }

  /// Non-blocking read. Returns:
  ///   * non-empty List<Num>  — bytes ready
  ///   * empty List           — EOF
  ///   * null                 — no data available right now
  /// Cooperative fiber loop:
  ///   while (true) {
  ///     var chunk = conn.tryRead(4096)
  ///     if (chunk == null) { Fiber.yield() } else { ... break }
  ///   }
  tryRead(max) { SocketCore.tcpTryRead(_id, max) }

  /// Write every byte of `data` (String or List<Num>). Blocks
  /// until the OS accepts the full payload. Returns the number of
  /// bytes written.
  write(data) { SocketCore.tcpWrite(_id, data) }

  /// Apply a per-read timeout in milliseconds. A subsequent
  /// `read` that waits longer than this fails with a runtime
  /// error. Pass null to clear.
  setReadTimeout(ms) {
    SocketCore.tcpSetReadTimeout(_id, ms)
    return null
  }

  peerAddr  { SocketCore.tcpPeerAddr(_id) }
  localAddr { SocketCore.tcpLocalAddr(_id) }

  /// Shut down both halves and release the OS handle. Calling
  /// `close` twice is safe — the second call is a no-op.
  close {
    SocketCore.tcpClose(_id)
    return null
  }

  id_ { _id }
}

class UdpSocket {
  /// Bind a datagram socket. Like TcpListener, port 0 asks the
  /// OS for a free port.
  static bind(addr) {
    if (!(addr is String)) Fiber.abort("UdpSocket.bind: addr must be a string")
    return UdpSocket.new_(SocketCore.udpBind(addr))
  }

  construct new_(id) {
    _id = id
  }

  /// Send `data` (String or List<Num>) to `dest` ("host:port"),
  /// returning the number of bytes actually sent. UDP is packet-
  /// oriented: writes are all-or-nothing up to the MTU.
  sendTo(data, dest) {
    if (!(dest is String)) Fiber.abort("UdpSocket.sendTo: dest must be a string")
    return SocketCore.udpSendTo(_id, data, dest)
  }

  /// Block for the next datagram, returning `[bytes, fromAddr]`.
  /// `bytes` is a List<Num>, `fromAddr` is a String. Each recv
  /// reads exactly one datagram.
  recvFrom(max) { SocketCore.udpRecvFrom(_id, max) }

  /// Non-blocking recvFrom. Returns `[bytes, fromAddr]` or `null`
  /// when no datagram is buffered.
  tryRecvFrom(max) { SocketCore.udpTryRecvFrom(_id, max) }

  address { SocketCore.udpLocalAddr(_id) }

  close {
    SocketCore.udpClose(_id)
    return null
  }

  id_ { _id }
}
