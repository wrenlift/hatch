import "./hash"        for Hash
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// Test vectors: known-answer pairs from RFC / NIST so any future
// back-end swap still surfaces discrepancies.

Test.describe("hex digests") {
  Test.it("md5('hello')") {
    Expect.that(Hash.md5("hello"))
      .toBe("5d41402abc4b2a76b9719d911017c592")
  }
  Test.it("sha1('hello')") {
    Expect.that(Hash.sha1("hello"))
      .toBe("aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d")
  }
  Test.it("sha256('hello')") {
    Expect.that(Hash.sha256("hello"))
      .toBe("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
  }
  Test.it("sha512('hello')") {
    Expect.that(Hash.sha512("hello"))
      .toBe(
        "9b71d224bd62f3785d96d46ad3ea3d73319bfbc2890caadae2dff72519673ca7" +
        "2323c3d99ba5c11d7c7acc6e14b8c5da0c4663475c2e5c3adef46f73bcdec043"
      )
  }
  Test.it("empty string digests") {
    Expect.that(Hash.sha256(""))
      .toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  }
  Test.it("different inputs produce different digests") {
    // Sanity check that the back-end isn't returning a fixed
    // string. Empty vs "x" vs "y" should all disagree.
    var a = Hash.sha256("")
    var b = Hash.sha256("x")
    var c = Hash.sha256("y")
    Expect.that(a != b).toBe(true)
    Expect.that(b != c).toBe(true)
  }
}

Test.describe("byte digests") {
  Test.it("sha256Bytes returns a 32-byte list") {
    var bs = Hash.sha256Bytes("hello")
    Expect.that(bs.count).toBe(32)
    Expect.that(bs[0]).toBe(44)    // 0x2c
  }
  Test.it("sha1Bytes returns a 20-byte list") {
    Expect.that(Hash.sha1Bytes("hello").count).toBe(20)
  }
  Test.it("md5Bytes returns a 16-byte list") {
    Expect.that(Hash.md5Bytes("hello").count).toBe(16)
  }
  Test.it("list-of-bytes input roundtrips") {
    // "hi" = [104, 105]
    Expect.that(Hash.sha256("hi")).toBe(Hash.sha256([104, 105]))
  }
}

Test.describe("HMAC") {
  Test.it("hmacSha256(key='key', msg='The quick brown fox jumps over the lazy dog')") {
    // RFC 4231 test vector-ish; well-known value from Wikipedia.
    Expect.that(Hash.hmacSha256("key", "The quick brown fox jumps over the lazy dog"))
      .toBe("f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
  }
  Test.it("hmacSha1 on RFC 2202 vector #1") {
    // key = 0x0b * 20, data = "Hi There"
    var key = [11, 11, 11, 11, 11, 11, 11, 11, 11, 11,
               11, 11, 11, 11, 11, 11, 11, 11, 11, 11]
    Expect.that(Hash.hmacSha1(key, "Hi There"))
      .toBe("b617318655057264e28bc0b6fb378c8ef146be00")
  }
}

Test.describe("base64") {
  Test.it("encode 'hello' → 'aGVsbG8='") {
    Expect.that(Hash.base64Encode("hello")).toBe("aGVsbG8=")
  }
  Test.it("decode roundtrips") {
    var bytes = Hash.base64Decode("aGVsbG8=")
    Expect.that(bytes).toEqual([104, 101, 108, 108, 111])
  }
  Test.it("empty input / empty output") {
    Expect.that(Hash.base64Encode("")).toBe("")
    Expect.that(Hash.base64Decode("")).toEqual([])
  }
  Test.it("invalid base64 aborts") {
    var e = Fiber.new { Hash.base64Decode("!!!") }.try()
    Expect.that(e).toContain("base64Decode")
  }
  Test.it("URL-safe variant has no padding + different alphabet") {
    // 0xFB 0xFF = "+/" in standard base64, "-_" in URL-safe.
    Expect.that(Hash.base64Encode([251, 255])).toBe("+/8=")
    Expect.that(Hash.base64UrlEncode([251, 255])).toBe("-_8")
  }
  Test.it("URL-safe roundtrip") {
    var s = "fn+=sub/dir"
    var encoded = Hash.base64UrlEncode(s)
    var decoded = Hash.base64UrlDecode(encoded)
    // Decode yields bytes; recompose into a string by round-trip
    // through standard encode to verify the bytes match the
    // input's UTF-8 form.
    Expect.that(Hash.base64UrlEncode(decoded)).toBe(encoded)
  }
}

Test.describe("input validation") {
  Test.it("out-of-range byte aborts") {
    var e = Fiber.new { Hash.sha256([0, 300]) }.try()
    Expect.that(e).toContain("0..=255")
  }
  Test.it("non-list/non-string aborts") {
    var e = Fiber.new { Hash.sha256(42) }.try()
    Expect.that(e).toContain("string")
  }
}

Test.run()
