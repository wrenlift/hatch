// `@hatch:crypto`: AES-256-GCM, Ed25519, and CSPRNG.
//
// ```wren
// import "@hatch:crypto" for Aes, Ed25519, Crypto
//
// // Symmetric authenticated encryption (AES-256-GCM)
// var key   = Aes.key                     // 32 fresh random bytes
// var nonce = Aes.nonce                   // 12 fresh random bytes
// var ct    = Aes.encrypt(key, nonce, "hello world")
// var pt    = Aes.decrypt(key, nonce, ct) // List<Num> of "hello world"
//
// // Ed25519 signatures
// var pair = Ed25519.keypair               // [secret, public]; 32 bytes each
// var sig  = Ed25519.sign(pair[0], "message")
// Ed25519.verify(pair[1], "message", sig)  // true
//
// // Cryptoness
// Crypto.bytes(16)    // List<Num>, 16 cryptographically-random bytes
// ```
//
// Byte conventions match `@hatch:hash`: inputs are either
// `String`s (UTF-8 bytes) or `List<Num>`; outputs are always
// `List<Num>`.
//
// AES-GCM is the default modern authenticated mode: one
// roundtrip protects confidentiality, integrity, and AAD. Key
// must be 32 bytes, nonce must be 12, **and the same nonce must
// NEVER be reused under the same key**. Generate fresh nonces
// via `Aes.nonce` per message.
//
// Ed25519 signing keys are 32 bytes, public keys are 32 bytes,
// signatures are 64 bytes. `verify` returns `false` on any
// mismatch (wrong key, tampered message, wrong signature length,
// whatever). Never aborts mid-verify, so signature check is
// branch-free.
//
// Backed by RustCrypto (`aes-gcm`), `ed25519-dalek`, and an
// OS-seeded CSPRNG via `rand_core`.

import "crypto" for CryptoCore

class Aes {
  /// Generate a fresh 32-byte key from the OS CSPRNG. Store it
  /// securely; anyone with the key can decrypt the messages.
  static key   { CryptoCore.aesGcmKey() }

  /// Generate a fresh 12-byte nonce from the OS CSPRNG. Must be
  /// unique per (key, message); reusing a nonce with the same
  /// key breaks AES-GCM's security entirely. Generate a fresh
  /// one per encryption.
  static nonce { CryptoCore.aesGcmNonce() }

  /// Encrypt. `key` must be 32 bytes, `nonce` must be 12.
  /// `plaintext` is a String or List<Num>. Returns ciphertext
  /// as List<Num> (includes the 16-byte auth tag at the end).
  static encrypt(key, nonce, plaintext)      { encrypt(key, nonce, plaintext, null) }
  /// Same but with Additional Authenticated Data: bytes covered
  /// by the tag but not encrypted (context metadata, headers, etc.).
  static encrypt(key, nonce, plaintext, aad) {
    validateKey_(key, "Aes.encrypt")
    validateNonce_(nonce, "Aes.encrypt")
    return CryptoCore.aesGcmEncrypt(key, nonce, plaintext, aad)
  }

  /// Decrypt. Returns the plaintext List<Num> on success, or
  /// `null` on ANY failure (wrong key, wrong nonce, tampered
  /// ciphertext, mismatched AAD). All failures are
  /// indistinguishable by design; a malicious attacker learns
  /// nothing from the outcome beyond "didn't decrypt cleanly".
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
    // Accept either a List<Num> or a ByteArray; both expose
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
  /// Generate a fresh signing keypair. Returns [secret, public],
  /// both 32-byte List<Num>s. Secret is the signing key; never
  /// share it. Public can be distributed freely.
  static keypair { CryptoCore.ed25519Keypair() }

  /// Derive the matching public key from a secret. Useful when
  /// only the secret is persisted and the public key is needed
  /// on demand.
  static publicFromSecret(secret) {
    if (!((secret is List) || (secret is ByteArray)) || secret.count != 32) {
      Fiber.abort("Ed25519.publicFromSecret: secret must be a 32-byte list")
    }
    return CryptoCore.ed25519PublicFromSecret(secret)
  }

  /// Sign a message (String or byte list). Returns a 64-byte
  /// signature as List<Num>. Same message and same secret always
  /// produce the same signature (Ed25519 is deterministic).
  static sign(secret, message) {
    if (!((secret is List) || (secret is ByteArray)) || secret.count != 32) {
      Fiber.abort("Ed25519.sign: secret must be a 32-byte list")
    }
    return CryptoCore.ed25519Sign(secret, message)
  }

  /// Verify a signature against (public, message). Returns true
  /// iff everything lines up; false on any mismatch. Never
  /// aborts; a wrong-length signature, public key, or anything
  /// else produces `false`, not a throw, so auth flows don't
  /// need error handling around a simple "is this valid" check.
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

/// Convenience for generic secure randomness. A bigger surface,
/// `@hatch:random`, exists for non-crypto uses (games, sampling,
/// simulations) and uses a faster, seedable, non-cryptographic
/// PRNG. Use `Crypto.bytes` here only for values that could face
/// an adversary (keys, nonces, session IDs, salts).
class Crypto {
  static bytes(n) {
    if (!(n is Num) || !n.isInteger || n < 0) {
      Fiber.abort("Crypto.bytes: count must be a non-negative integer")
    }
    return CryptoCore.randomBytes(n)
  }
}

/// Password hashing; argon2id by default.
///
/// Argon2id is OWASP's current recommendation (2024+): memory-hard,
/// resistant to GPU/ASIC cracking, and parameterised so the cost
/// can grow as hardware does. Use it for any value a human will
/// ever type: account passwords, passphrase-derived keys, API
/// token recovery codes.
///
/// ```wren
/// var hash = Password.hash("correct horse battery staple")
/// // -> "$argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>"
///
/// Password.verify("correct horse battery staple", hash)  // true
/// Password.verify("wrong", hash)                         // false
/// ```
///
/// The hash string is self-describing (PHC format); it embeds the
/// algorithm, parameters, salt, and digest. Store it as-is and
/// pass it back to `verify`. No "what params did I use" bookkeeping.
///
/// Default params target ~50-80ms per hash on commodity hardware
/// (`m=19456` KiB, `t=2`, `p=1`). Tune upward with `hashWith` as
/// scale grows; the point is to keep hashing slow for an attacker
/// while fast enough for a real login.
///
/// Never store a plaintext password, never hash with SHA-anything,
/// and never use MD5, SHA-1, or bcrypt for *new* code. `@hatch:hash`
/// is for message digests; `Password` is the only thing in the
/// ecosystem that should touch user passwords.
class Password {
  /// Hash a password with OWASP-default argon2id params. Returns
  /// a PHC-format String. Each call generates a fresh salt, so
  /// hashing the same password twice produces different strings;
  /// both verify against the original.
  static hash(password) {
    if (!((password is String) || (password is List) || (password is ByteArray))) {
      Fiber.abort("Password.hash: password must be a String or byte list")
    }
    return CryptoCore.argon2Hash(password)
  }

  /// Verify `password` against a previously-stored PHC hash.
  /// Returns true iff the hash matches. Never aborts on a
  /// malformed hash string; returns false instead, so auth flows
  /// stay branch-free and don't leak "is this a valid PHC
  /// string?" side-channels.
  static verify(password, hash) {
    if (!((password is String) || (password is List) || (password is ByteArray))) {
      Fiber.abort("Password.verify: password must be a String or byte list")
    }
    if (!(hash is String)) {
      Fiber.abort("Password.verify: hash must be a String")
    }
    return CryptoCore.argon2Verify(password, hash)
  }

  /// Hash with custom argon2id params. `m` is memory in KiB,
  /// `t` is iterations, `p` is parallelism lanes. Use when a
  /// stricter (slower) or relaxed (embedded / CI) profile is
  /// needed instead of the defaults. Producing hashes verifiable
  /// against `Password.verify` requires argon2id; other
  /// algorithms are currently not exposed.
  static hashWith(password, m, t, p) {
    if (!((password is String) || (password is List) || (password is ByteArray))) {
      Fiber.abort("Password.hashWith: password must be a String or byte list")
    }
    if (!(m is Num) || !m.isInteger || m <= 0) {
      Fiber.abort("Password.hashWith: m must be a positive integer (KiB)")
    }
    if (!(t is Num) || !t.isInteger || t <= 0) {
      Fiber.abort("Password.hashWith: t must be a positive integer (iterations)")
    }
    if (!(p is Num) || !p.isInteger || p <= 0) {
      Fiber.abort("Password.hashWith: p must be a positive integer (lanes)")
    }
    return CryptoCore.argon2HashWith(password, m, t, p)
  }
}
