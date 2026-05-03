AES-256-GCM authenticated encryption, Ed25519 signatures, and an OS-seeded CSPRNG. Three classes (`Aes`, `Ed25519`, `Crypto`) cover the symmetric-encryption, signature, and random-bytes corners of a small modern crypto stack. Backed by RustCrypto's `aes-gcm` and `ed25519-dalek`, with `rand_core` driving the random source.

## Overview

Inputs are either `String` (interpreted as UTF-8 bytes) or `List<Num>` / `ByteArray`. Outputs are always `List<Num>`. That convention matches `@hatch:hash`, so chaining hash + sign or hash + encrypt doesn't need byte-shape gymnastics.

```wren
import "@hatch:crypto" for Aes, Ed25519, Crypto

var key   = Aes.key
var nonce = Aes.nonce
var ct    = Aes.encrypt(key, nonce, "hello world")
var pt    = Aes.decrypt(key, nonce, ct)

var pair = Ed25519.keypair
var sig  = Ed25519.sign(pair[0], "message")
System.print(Ed25519.verify(pair[1], "message", sig)) // true

System.print(Crypto.bytes(16))
```

`Aes.encrypt` accepts an optional `aad` (additional authenticated data: bytes covered by the GCM tag but not encrypted, useful for headers and context). `Aes.decrypt` returns `null` on any failure: wrong key, wrong nonce, tampered ciphertext, and mismatched AAD all surface identically by design, so a verifier learns nothing about why the check failed.

## Notes on use

> **Warning: never reuse a GCM nonce**
> AES-GCM's security collapses entirely if two messages are encrypted with the same `(key, nonce)` pair. Always generate a fresh `Aes.nonce` per encryption; never derive it from message content or a counter outside the caller's control.

`Ed25519.verify` is branch-free with respect to inputs; it returns `false` on any mismatch and never aborts mid-verify, so timing leaks via control flow aren't a concern. Signing keys and public keys are both 32 bytes; signatures are 64.

> **Note: store keys, not strings**
> The library doesn't ship a key-management layer. Persist key bytes through `@hatch:fs` (with appropriate permissions) or hand them off to a host secrets manager. Encoding via `@hatch:hash` hex or base64 helpers is fine for transport; just don't put raw keys into source control.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Native only; `#!wasm` builds cannot pull this package in directly. Route browser-side crypto through the SubtleCrypto bridge in `@hatch:web`.
