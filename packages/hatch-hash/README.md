Cryptographic hashes (MD5, SHA-1, SHA-256, SHA-512), HMAC, and base64. One class, `Hash`, exposing one-shot digests in both hex (the default for human-readable output) and raw-bytes flavours when feeding another primitive. Backed by RustCrypto and the `base64` crate via the runtime `hash` module.

## Overview

Inputs are either `String` (interpreted as UTF-8 bytes) or `List<Num>` / `ByteArray` in `0..=255`. Hex helpers return lowercase strings; byte helpers return `List<Num>`. The naming mirrors the underlying primitive: pick the digest, suffix `Bytes` for raw output.

```wren
import "@hatch:hash" for Hash

System.print(Hash.sha256("hello"))
// 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824

System.print(Hash.hmacSha256("secret", "hello"))
// 88aab3ede8d3adf94d26ab90d3bafd4a2083070c3bcce9c014ee04a443847c0b

System.print(Hash.base64Encode("hello"))           // "aGVsbG8="
System.print(Hash.base64Decode("aGVsbG8="))        // [104, 101, 108, 108, 111]

System.print(Hash.base64UrlEncode([1, 2, 3]))      // unpadded URL-safe variant
```

`base64UrlEncode` / `base64UrlDecode` use the JWT-flavoured URL-safe alphabet without padding. Pair with `@hatch:crypto`'s Ed25519 helpers to roll signed tokens.

## Choosing a primitive

| Primitive | Use it for | Notes |
|-----------|------------|-------|
| `md5`     | Cache keys, content fingerprints in non-adversarial contexts | Broken for security; never use it for password / signature work. |
| `sha1`    | Compatibility with legacy systems | Also broken for collision-resistance; treat the same as MD5. |
| `sha256`  | Default modern choice | Content addressing, integrity checks, signature pre-image. |
| `sha512`  | Same threat model as 256, larger digest | Slightly faster on 64-bit hosts. |

> **Note: no constant-time compare yet.**
> The package doesn't ship a constant-time string comparison. To compare HMACs against attacker-supplied input, compare byte-by-byte against the `*Bytes` helpers and fold differences into a single accumulator. A native `Hash.compare` may land if a real auth use case asks for it.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Native only. `#!wasm` builds reach for SubtleCrypto via `@hatch:web`.
