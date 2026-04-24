import "./crypto"      for Aes, Ed25519, Crypto, Password
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- Crypto ----------------------------------------------------

Test.describe("Crypto.bytes") {
  Test.it("returns the requested count") {
    Expect.that(Crypto.bytes(16).count).toBe(16)
    Expect.that(Crypto.bytes(0).count).toBe(0)
    Expect.that(Crypto.bytes(64).count).toBe(64)
  }
  Test.it("two calls produce different bytes") {
    var a = Crypto.bytes(32)
    var b = Crypto.bytes(32)
    // Vanishingly unlikely two CSPRNG 32-byte draws are equal.
    var same = true
    var i = 0
    while (i < 32) {
      if (a[i] != b[i]) same = false
      i = i + 1
    }
    Expect.that(same).toBe(false)
  }
  Test.it("every byte in 0..=255") {
    var b = Crypto.bytes(256)
    var i = 0
    while (i < b.count) {
      Expect.that(b[i] >= 0).toBe(true)
      Expect.that(b[i] <= 255).toBe(true)
      i = i + 1
    }
  }
  Test.it("negative count aborts") {
    var e = Fiber.new { Crypto.bytes(-1) }.try()
    Expect.that(e).toContain("non-negative")
  }
}

// --- AES-256-GCM -----------------------------------------------

Test.describe("Aes.key + Aes.nonce") {
  Test.it("key is 32 bytes") {
    Expect.that(Aes.key.count).toBe(32)
  }
  Test.it("nonce is 12 bytes") {
    Expect.that(Aes.nonce.count).toBe(12)
  }
  Test.it("two keys differ") {
    var a = Aes.key
    var b = Aes.key
    var same = true
    var i = 0
    while (i < 32) {
      if (a[i] != b[i]) same = false
      i = i + 1
    }
    Expect.that(same).toBe(false)
  }
}

Test.describe("Aes.encrypt / Aes.decrypt round-trip") {
  Test.it("string plaintext") {
    var k = Aes.key
    var n = Aes.nonce
    var ct = Aes.encrypt(k, n, "hello world")
    var pt = Aes.decrypt(k, n, ct)
    Expect.that(pt.count).toBe(11)
    // Decode bytes back to string by indexing — skip the Buffer
    // round-trip to keep this spec standalone.
    Expect.that(pt[0]).toBe(0x68) // h
    Expect.that(pt[10]).toBe(0x64) // d
  }
  Test.it("binary plaintext (List<Num>) round-trip") {
    var k = Aes.key
    var n = Aes.nonce
    var msg = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    var ct = Aes.encrypt(k, n, msg)
    var pt = Aes.decrypt(k, n, ct)
    Expect.that(pt.count).toBe(10)
    var i = 0
    while (i < 10) {
      Expect.that(pt[i]).toBe(i)
      i = i + 1
    }
  }
  Test.it("ciphertext longer than plaintext (16-byte tag)") {
    var k = Aes.key
    var n = Aes.nonce
    var ct = Aes.encrypt(k, n, "x")
    // Plaintext 1 byte → ciphertext 17 (1 + 16 tag).
    Expect.that(ct.count).toBe(17)
  }
}

Test.describe("Aes auth failures") {
  Test.it("tampered ciphertext → null") {
    var k = Aes.key
    var n = Aes.nonce
    var ct = Aes.encrypt(k, n, "secret")
    // Flip one byte.
    ct[0] = (ct[0] + 1) % 256
    Expect.that(Aes.decrypt(k, n, ct)).toBeNull()
  }
  Test.it("wrong key → null") {
    var k1 = Aes.key
    var k2 = Aes.key
    var n  = Aes.nonce
    var ct = Aes.encrypt(k1, n, "secret")
    Expect.that(Aes.decrypt(k2, n, ct)).toBeNull()
  }
  Test.it("wrong nonce → null") {
    var k  = Aes.key
    var n1 = Aes.nonce
    var n2 = Aes.nonce
    var ct = Aes.encrypt(k, n1, "secret")
    Expect.that(Aes.decrypt(k, n2, ct)).toBeNull()
  }
}

Test.describe("Aes AAD") {
  Test.it("AAD round-trip") {
    var k = Aes.key
    var n = Aes.nonce
    var ct = Aes.encrypt(k, n, "hi", "header-info")
    var pt = Aes.decrypt(k, n, ct, "header-info")
    Expect.that(pt.count).toBe(2)
  }
  Test.it("mismatched AAD → null") {
    var k = Aes.key
    var n = Aes.nonce
    var ct = Aes.encrypt(k, n, "hi", "header-A")
    Expect.that(Aes.decrypt(k, n, ct, "header-B")).toBeNull()
  }
}

Test.describe("Aes validation") {
  Test.it("bad key size aborts") {
    var e = Fiber.new {
      Aes.encrypt([1, 2, 3], Aes.nonce, "x")
    }.try()
    Expect.that(e).toContain("32-byte")
  }
  Test.it("bad nonce size aborts") {
    var e = Fiber.new {
      Aes.encrypt(Aes.key, [1, 2, 3], "x")
    }.try()
    Expect.that(e).toContain("12-byte")
  }
}

// --- Ed25519 ---------------------------------------------------

Test.describe("Ed25519.keypair") {
  Test.it("returns [secret, public], each 32 bytes") {
    var p = Ed25519.keypair
    Expect.that(p.count).toBe(2)
    Expect.that(p[0].count).toBe(32)
    Expect.that(p[1].count).toBe(32)
  }
  Test.it("publicFromSecret matches keypair's public") {
    var p = Ed25519.keypair
    var pub2 = Ed25519.publicFromSecret(p[0])
    Expect.that(pub2.count).toBe(32)
    var i = 0
    while (i < 32) {
      Expect.that(pub2[i]).toBe(p[1][i])
      i = i + 1
    }
  }
}

Test.describe("Ed25519.sign + verify") {
  Test.it("valid signature verifies") {
    var p = Ed25519.keypair
    var sig = Ed25519.sign(p[0], "hello")
    Expect.that(sig.count).toBe(64)
    Expect.that(Ed25519.verify(p[1], "hello", sig)).toBe(true)
  }
  Test.it("different message → verify false") {
    var p = Ed25519.keypair
    var sig = Ed25519.sign(p[0], "hello")
    Expect.that(Ed25519.verify(p[1], "world", sig)).toBe(false)
  }
  Test.it("different key → verify false") {
    var p1 = Ed25519.keypair
    var p2 = Ed25519.keypair
    var sig = Ed25519.sign(p1[0], "hello")
    Expect.that(Ed25519.verify(p2[1], "hello", sig)).toBe(false)
  }
  Test.it("tampered signature → false") {
    var p = Ed25519.keypair
    var sig = Ed25519.sign(p[0], "hello")
    sig[0] = (sig[0] + 1) % 256
    Expect.that(Ed25519.verify(p[1], "hello", sig)).toBe(false)
  }
  Test.it("wrong-length key/sig → false, no abort") {
    var p = Ed25519.keypair
    var sig = Ed25519.sign(p[0], "hello")
    // 31-byte public
    var shortPub = []
    var i = 0
    while (i < 31) {
      shortPub.add(p[1][i])
      i = i + 1
    }
    Expect.that(Ed25519.verify(shortPub, "hello", sig)).toBe(false)
    // 63-byte sig
    var shortSig = []
    i = 0
    while (i < 63) {
      shortSig.add(sig[i])
      i = i + 1
    }
    Expect.that(Ed25519.verify(p[1], "hello", shortSig)).toBe(false)
  }
  Test.it("signing is deterministic") {
    var p = Ed25519.keypair
    var a = Ed25519.sign(p[0], "same message")
    var b = Ed25519.sign(p[0], "same message")
    var i = 0
    while (i < 64) {
      Expect.that(a[i]).toBe(b[i])
      i = i + 1
    }
  }
}

Test.describe("Ed25519 validation") {
  Test.it("sign with wrong-length secret aborts") {
    var e = Fiber.new { Ed25519.sign([1, 2, 3], "hi") }.try()
    Expect.that(e).toContain("32-byte")
  }
}

// --- Password (argon2id) --------------------------------------
//
// The hash/verify round-trip is slow (~50-80ms per hash by
// design). Use relaxed params for spec runs via `hashWith` where
// possible so the suite stays fast.

Test.describe("Password.hash / verify") {
  Test.it("round-trips with default params") {
    var h = Password.hash("correct horse battery staple")
    Expect.that(h is String).toBe(true)
    Expect.that(h.startsWith("$argon2id$")).toBe(true)
    Expect.that(Password.verify("correct horse battery staple", h)).toBe(true)
  }

  Test.it("rejects wrong password") {
    var h = Password.hashWith("swordfish", 8192, 1, 1)
    Expect.that(Password.verify("swordfis",  h)).toBe(false)
    Expect.that(Password.verify("swordfish!", h)).toBe(false)
    Expect.that(Password.verify("", h)).toBe(false)
  }

  Test.it("same password + different call → different hash (fresh salt)") {
    var a = Password.hashWith("hunter2", 8192, 1, 1)
    var b = Password.hashWith("hunter2", 8192, 1, 1)
    Expect.that(a).not.toBe(b)
    Expect.that(Password.verify("hunter2", a)).toBe(true)
    Expect.that(Password.verify("hunter2", b)).toBe(true)
  }

  Test.it("verify accepts String and byte list equally") {
    var h = Password.hashWith("utf-8 café", 8192, 1, 1)
    Expect.that(Password.verify("utf-8 café", h)).toBe(true)
    // Same string as a byte list — must match, since the hasher
    // sees bytes either way.
    var bytes = [117, 116, 102, 45, 56, 32, 99, 97, 102, 195, 169]
    Expect.that(Password.verify(bytes, h)).toBe(true)
  }

  Test.it("malformed hash string returns false (no abort)") {
    Expect.that(Password.verify("any", "not a PHC string")).toBe(false)
    Expect.that(Password.verify("any", "$argon2id$broken")).toBe(false)
    Expect.that(Password.verify("any", "")).toBe(false)
  }

  Test.it("hashWith rejects non-positive params") {
    var e1 = Fiber.new { Password.hashWith("x", 0, 1, 1) }.try()
    Expect.that(e1).toContain("positive integer")
    var e2 = Fiber.new { Password.hashWith("x", 8192, 0, 1) }.try()
    Expect.that(e2).toContain("positive integer")
    var e3 = Fiber.new { Password.hashWith("x", 8192, 1, 0) }.try()
    Expect.that(e3).toContain("positive integer")
  }

  Test.it("hash rejects non-string / non-bytes input") {
    var e = Fiber.new { Password.hash(42) }.try()
    Expect.that(e).toContain("must be a String or byte list")
  }
}

Test.run()
