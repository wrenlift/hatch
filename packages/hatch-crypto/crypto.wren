// @hatch:crypto — AES-256-GCM + Ed25519 + CSPRNG.
//
//   import "@hatch:crypto" for Aes, Ed25519, Crypto
//
//   // Symmetric authenticated encryption (AES-256-GCM)
//   var key   = Aes.key                     // 32 fresh random bytes
//   var nonce = Aes.nonce                   // 12 fresh random bytes
//   var ct    = Aes.encrypt(key, nonce, "hello world")
//   var pt    = Aes.decrypt(key, nonce, ct) // List<Num> of "hello world"
//
//   // Ed25519 signatures
//   var pair = Ed25519.keypair               // [secret, public] — 32 bytes each
//   var sig  = Ed25519.sign(pair[0], "message")
//   Ed25519.verify(pair[1], "message", sig)  // true
//
//   // Cryptoness
//   Crypto.bytes(16)    // List<Num>, 16 cryptographically-random bytes
//
// Byte conventions match @hatch:hash: inputs are either Strings
// (UTF-8 bytes) or List<Num>; outputs are always List<Num>.
//
// AES-GCM is the default modern authenticated mode: one roundtrip
// protects confidentiality + integrity + AAD. Key must be 32
// bytes, nonce must be 12, **and the same nonce must NEVER be
// reused under the same key**. Generate fresh nonces via
// `Aes.nonce` per message.
//
// Ed25519 signing keys are 32 bytes, public keys are 32 bytes,
// signatures are 64 bytes. Verify returns false on any mismatch —
// wrong key, tampered message, wrong signature length, whatever.
// Never aborts mid-verify so signature check is branch-free.
//
// Backed by RustCrypto (`aes-gcm`) + `ed25519-dalek` + OS-seeded
// CSPRNG via `rand_core`.

import "crypto" for CryptoCore

class Aes {
  // Generate a fresh 32-byte key from the OS CSPRNG. Store it
  // securely — anyone with the key can decrypt your messages.
  static key   { CryptoCore.aesGcmKey() }

  // Generate a fresh 12-byte nonce from the OS CSPRNG. Must be
  // unique per (key, message) — reusing a nonce with the same
  // key breaks AES-GCM's security entirely. Generate a fresh
  // one per encryption.
  static nonce { CryptoCore.aesGcmNonce() }

  // Encrypt. `key` must be 32 bytes, `nonce` must be 12.
  // `plaintext` is a String or List<Num>. Returns ciphertext
  // as List<Num> (includes the 16-byte auth tag at the end).
  static encrypt(key, nonce, plaintext)      { encrypt(key, nonce, plaintext, null) }
  // Same but with Additional Authenticated Data — bytes covered
  // by the tag but not encrypted (context metadata, headers, etc.).
  static encrypt(key, nonce, plaintext, aad) {
    validateKey_(key, "Aes.encrypt")
    validateNonce_(nonce, "Aes.encrypt")
    return CryptoCore.aesGcmEncrypt(key, nonce, plaintext, aad)
  }

  // Decrypt. Returns the plaintext List<Num> on success, or
  // `null` on ANY failure (wrong key, wrong nonce, tampered
  // ciphertext, mismatched AAD). All failures indistinguishable
  // by design — a malicious attacker learns nothing from the
  // outcome beyond "didn't decrypt cleanly".
  static decrypt(key, nonce, ciphertext)      { decrypt(key, nonce, ciphertext, null) }
  static decrypt(key, nonce, ciphertext, aad) {
    validateKey_(key, "Aes.decrypt")
    validateNonce_(nonce, "Aes.decrypt")
    if (!((ciphertext is List) || (ciphertext is ByteArray))) {
      Fiber.abort("Aes.decrypt: ciphertext must be a list of bytes")
    }
    return CryptoCore.aesGcmDecrypt(key, nonce, ciphertext, aad)
  }

  static validateKey_(k, label) {
    // Accept either a List<Num> or a ByteArray — both expose
    // .count and present as a byte-shaped payload to the runtime.
    if (!((k is List) || (k is ByteArray)) || k.count != 32) {
      Fiber.abort("%(label): key must be a 32-byte list")
    }
  }
  static validateNonce_(n, label) {
    if (!((n is List) || (n is ByteArray)) || n.count != 12) {
      Fiber.abort("%(label): nonce must be a 12-byte list")
    }
  }
}

class Ed25519 {
  // Generate a fresh signing keypair. Returns [secret, public],
  // both 32-byte List<Num>s. Secret is the signing key — never
  // share it. Public can be distributed freely.
  static keypair { CryptoCore.ed25519Keypair() }

  // Derive the matching public key from a secret. Useful when
  // you're persisting only the secret and need the public on
  // demand.
  static publicFromSecret(secret) {
    if (!((secret is List) || (secret is ByteArray)) || secret.count != 32) {
      Fiber.abort("Ed25519.publicFromSecret: secret must be a 32-byte list")
    }
    return CryptoCore.ed25519PublicFromSecret(secret)
  }

  // Sign a message (String or byte list). Returns a 64-byte
  // signature as List<Num>. Same message + same secret always
  // produces the same signature (Ed25519 is deterministic).
  static sign(secret, message) {
    if (!((secret is List) || (secret is ByteArray)) || secret.count != 32) {
      Fiber.abort("Ed25519.sign: secret must be a 32-byte list")
    }
    return CryptoCore.ed25519Sign(secret, message)
  }

  // Verify a signature against (public, message). Returns true
  // iff everything lines up; false on any mismatch. Never aborts
  // — wrong length signature / public key / anything produces
  // `false`, not a throw, so auth flows don't need error handling
  // around a simple "is this valid" check.
  static verify(public, message, signature) {
    if (!((public is List) || (public is ByteArray))) {
      Fiber.abort("Ed25519.verify: public must be a list")
    }
    if (!((signature is List) || (signature is ByteArray))) {
      Fiber.abort("Ed25519.verify: signature must be a list")
    }
    if (public.count != 32 || signature.count != 64) return false
    return CryptoCore.ed25519Verify(public, message, signature)
  }
}

// Convenience for generic secure randomness. Bigger surface —
// `@hatch:random` — exists for non-crypto uses (games, sampling,
// simulations) and uses a faster, seedable, non-cryptographic
// PRNG. Use `Crypto.bytes` here only when you need a value that
// could face an adversary (keys, nonces, session IDs, salts).
class Crypto {
  static bytes(n) {
    if (!(n is Num) || !n.isInteger || n < 0) {
      Fiber.abort("Crypto.bytes: count must be a non-negative integer")
    }
    return CryptoCore.randomBytes(n)
  }
}
