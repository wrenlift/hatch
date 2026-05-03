An HTTP/1.1 client with TLS, streaming bodies, and fiber-cooperative reads. The package exposes one namespace, `Http`, with a small set of one-shot verb helpers and a generic `Http.request(method, url, options)` for everything else. Built on Wren's native `Fiber`, so requests cooperate with whatever scheduler the host runs.

## Overview

A minute of code, then the reference.

The package gives you two surfaces. The verb helpers (`Http.get`, `Http.post`, ...) are one-shot calls that return a fully-buffered `Response`. The generic `Http.request(method, url, opts)` underneath them takes the same options and is the right call when the method is dynamic, when you want a streaming body, or when you want to fire-and-forget without parsing the response.

```wren
import "@hatch:http" for Http
import "@hatch:json" for JSON

var res = Http.get("https://api.wrenlift.com/status")
if (res.ok) {
  var body = JSON.parse(res.body)
  System.print("build: %(body[\"build\"])")
}
```

> **Tip: Fibers, not async**
> Wren fibers are cooperative. `Http.get` blocks the calling fiber until the response is back; under `@hatch:web`'s scheduler other fibers (other connections, refresh loops) keep running while one is parked on the wire. There is no `async` keyword to learn and no callback hell to manage.

## Posting

`Http.post` accepts a plain `String`, a `Map` (auto-encoded as JSON with the right `Content-Type`), or any value implementing `readChunk(maxLen)` for streaming uploads. The verb helpers `put`, `patch`, and `delete` follow the same shape; `delete` accepts no body.

```wren
var res = Http.post("https://api.wrenlift.com/v1/jobs", {
  "name": "build",
  "target": "linux/amd64"
}, {
  "headers": { "authorization": "Bearer %(token)" },
  "timeout": 5
})

System.print(res.status) // 201
```

> **Note: sandboxing**
> The client respects the workspace's net capability list. To allow outbound traffic, declare `net = ["api.wrenlift.com"]` in your `hatchfile`, or pass `--net` to `hatch run` for an unrestricted dev loop.

## Errors

Transport-layer failures (DNS, connect, TLS handshake, timeout) and malformed responses abort the calling fiber. Wrap in `Fiber.new { ... }.try()` to recover:

```wren
var f = Fiber.new { Http.get("https://flaky.example.com") }
var res = f.try()
if (f.error != null) {
  System.print("network error: %(f.error)")
}
```

> **Warning: backpressure is on you**
> The client does not queue or rate-limit on your behalf. Firing 1000 requests in a tight loop spawns 1000 sockets, and most operating systems will tip over before that finishes. Use `@hatch:web`'s `Scheduler_` or your own concurrency cap.

Native-side panics in transitive Rust dependencies surface the same way as fiber aborts, not process exits. The fiber is the recovery boundary.

## Compatibility

- Wren 0.4 and WrenLift runtime 0.1 or newer.
- TLS 1.2 / 1.3 via the host's native trust store.
- HTTP/1.1 only on the wire today. HTTP/2 negotiation lands when `@hatch:io`'s ALPN surface stabilises.

> The full **API reference** for `Http`, `Http.Client`, `Response`, and friends is auto-generated from the `///` doc comments in this package's source. There is no need to maintain it by hand here. Drop docs on declarations, run `hatch publish`, and the docs page picks them up from the bundle's `Docs` section.
