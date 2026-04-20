// @hatch:hash — cryptographic hashes, HMAC, base64.
//
//   import "@hatch:hash" for Hash
//
//   // One-shot digests. Input is a string (UTF-8 bytes) or
//   // a list of numbers in 0..=255.
//   Hash.md5("hello")        // hex digest, lowercase
//   Hash.sha1("hello")
//   Hash.sha256("hello")
//   Hash.sha512("hello")
//
//   // Raw bytes (List<Num>) when you need to feed another primitive.
//   Hash.sha256Bytes("hello")
//
//   // HMAC. key and message both accept string or bytes.
//   Hash.hmacSha1("secret", "hello")
//   Hash.hmacSha256("secret", "hello")
//   Hash.hmacSha512("secret", "hello")
//
//   // Base64. Encode takes string/bytes, decode returns bytes.
//   Hash.base64Encode("hello")       // "aGVsbG8="
//   Hash.base64Decode("aGVsbG8=")    // [104, 101, 108, 108, 111]
//
//   // URL-safe variant (JWT flavour, no padding).
//   Hash.base64UrlEncode(bytes)
//   Hash.base64UrlDecode(text)
//
// Backed by RustCrypto + base64 crates via the runtime `hash`
// module. Constant-time comparisons aren't exposed — we'll add a
// `compare` helper if auth use cases demand it.

import "hash" for HashCore

class Hash {
  // --- Hex digests ------------------------------------------------------

  static md5(data)    { HashCore.md5Hex(data) }
  static sha1(data)   { HashCore.sha1Hex(data) }
  static sha256(data) { HashCore.sha256Hex(data) }
  static sha512(data) { HashCore.sha512Hex(data) }

  // --- Byte-returning digests -------------------------------------------

  static md5Bytes(data)    { HashCore.md5Bytes(data) }
  static sha1Bytes(data)   { HashCore.sha1Bytes(data) }
  static sha256Bytes(data) { HashCore.sha256Bytes(data) }
  static sha512Bytes(data) { HashCore.sha512Bytes(data) }

  // --- HMAC -------------------------------------------------------------

  static hmacSha1(key, message)   { HashCore.hmacSha1Hex(key, message) }
  static hmacSha256(key, message) { HashCore.hmacSha256Hex(key, message) }
  static hmacSha512(key, message) { HashCore.hmacSha512Hex(key, message) }

  // --- Base64 -----------------------------------------------------------

  static base64Encode(data)       { HashCore.base64Encode(data) }
  static base64Decode(text)       { HashCore.base64Decode(text) }
  static base64UrlEncode(data)    { HashCore.base64UrlEncode(data) }
  static base64UrlDecode(text)    { HashCore.base64UrlDecode(text) }
}
