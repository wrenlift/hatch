A URL parser, builder, and percent-encoder. One class — `Url` — with parse, build, and round-trip serialization, plus standalone helpers for component encoding and `key=value` query strings. Pure Wren, follows RFC 3986 loosely; scope is "good-enough" URL handling for HTTP requests and link generation.

## Overview

Parse a string and read named parts back out, or build one piece-by-piece and serialize. The `Url` value-type has setters for every component, so mutation works without reaching into private state.

```wren
import "@hatch:url" for Url

var u = Url.parse("https://user:pass@example.com:8080/path?q=s&x=1#frag")
System.print(u.scheme)     // "https"
System.print(u.host)       // "example.com"
System.print(u.port)       // 8080
System.print(u.path)       // "/path"
System.print(u.queryMap)   // { "q": "s", "x": "1" }

u.path = "/v2/path"
u.queryMap = { "q": "hello world" }
System.print(u.toString)
// https://user:pass@example.com:8080/v2/path?q=hello%20world#frag
```

`u.toString` round-trips back to the canonical form; `u.queryMap` is a parsed `Map` view that round-trips through `Url.decodeQuery` and `Url.encodeQuery`.

## Encoding helpers

```wren
System.print(Url.encode("a b/c"))                  // "a%20b%2Fc"
System.print(Url.decode("a%20b%2Fc"))              // "a b/c"

System.print(Url.encodeQuery({ "a": 1, "b": "two" }))   // "a=1&b=two"
System.print(Url.decodeQuery("a=1&b=two"))               // { "a": "1", "b": "two" }
```

`encodeQuery` accepts `Num`, `String`, `Bool`, and `null` values; everything else aborts. Decoded values come back as strings — Wren doesn't have JSON-like type sniffing on the URL surface.

> **Note — what's not in scope**
> No IDN / punycode handling, no relative-URL resolution, no path-normalisation (`..` collapsing). If you need any of those, route through a host-side library on the way in. The package is sized for the "build a request URL and tear apart a redirect" job.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Pure-Wren — no native dependencies. Pair with `@hatch:http` for outbound requests; `Http.get` accepts plain strings, but pre-parsing through `Url` gives you query-map ergonomics.
