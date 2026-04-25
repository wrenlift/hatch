// @hatch:web/forms — schema-driven form validation.
//
// Declare a Field per input with chained transforms + validators.
// `Form.validate(params)` runs transforms first, then validators,
// and yields a FormResult with cleaned `data`, `errors`, and a
// `valid` flag — everything a template needs to re-render a
// filled-out form on failure.
//
//   var signup = Form.new([
//     Field.new("email").trim.lowercase
//                       .required("Email is required")
//                       .email("Looks invalid"),
//     Field.new("password").required("Password is required")
//                          .minLength(8, "At least 8 characters"),
//     Field.new("name").trim.maxLength(80, "Too long")
//   ])
//
//   app.post("/signup") {|req|
//     var r = signup.validate(req.form)
//     if (!r.valid) return renderSignup(req, r)
//     User.create(r.data)           // clean values, post-transform
//     return Response.redirect("/")
//   }
//
// All validators take an optional message. Without one, a sane
// default is emitted. Multiple validators on a field collect
// errors in declaration order — `errorsFor("email")` returns
// a List so templates can show them all; `firstError("email")`
// just the first.
//
// Transforms run BEFORE validators, so `.trim.required` means
// "strip whitespace, then require non-empty" — empty-after-trim
// triggers required. Validators DON'T mutate the value.

// ── Field ──────────────────────────────────────────────────────────────

class Field {
  construct new(name) {
    _name = name
    _transforms = []     // list of Fn(val) -> val
    _validators = []     // list of ["name", Fn(val) -> msg?, msg?]
    _optional = false    // required() disables this; default is required-by-missing
  }

  name { _name }

  // ── transforms ────────────────────────────────────────────────

  // Strip leading / trailing ASCII whitespace (space, tab, \n, \r).
  trim {
    _transforms.add(Fn.new {|v| Field.trim_(v) })
    return this
  }

  lowercase {
    _transforms.add(Fn.new {|v| v is String ? Field.toLower_(v) : v })
    return this
  }

  uppercase {
    _transforms.add(Fn.new {|v| v is String ? Field.toUpper_(v) : v })
    return this
  }

  // Fallback when the field is absent or empty-after-transforms.
  // Runs BEFORE validators so `required` sees the default.
  default_(value) {
    _transforms.add(Fn.new {|v|
      if (v == null || v == "") return value
      return v
    })
    return this
  }

  // Arbitrary transform. Fn takes the current value, returns new.
  transform(fn) {
    _transforms.add(fn)
    return this
  }

  // ── validators ────────────────────────────────────────────────

  required    { required("This field is required") }
  required(msg) {
    _validators.add(["required", Fn.new {|v|
      if (v == null || (v is String && v.count == 0)) return msg
      return null
    }])
    return this
  }

  email       { email("Enter a valid email address") }
  email(msg) {
    _validators.add(["email", Fn.new {|v|
      if (v == null || !(v is String) || v.count == 0) return null  // let required catch
      if (!Field.looksLikeEmail_(v)) return msg
      return null
    }])
    return this
  }

  // Absolute-or-relative URL with a scheme. Rejects javascript:
  // and data: out of hand.
  url        { url("Enter a valid URL") }
  url(msg) {
    _validators.add(["url", Fn.new {|v|
      if (v == null || !(v is String) || v.count == 0) return null
      if (!Field.looksLikeUrl_(v)) return msg
      return null
    }])
    return this
  }

  minLength(n)      { minLength(n, "Must be at least %(n) characters") }
  minLength(n, msg) {
    _validators.add(["minLength", Fn.new {|v|
      if (v == null || !(v is String)) return null
      if (v.count < n) return msg
      return null
    }])
    return this
  }

  maxLength(n)      { maxLength(n, "Must be at most %(n) characters") }
  maxLength(n, msg) {
    _validators.add(["maxLength", Fn.new {|v|
      if (v == null || !(v is String)) return null
      if (v.count > n) return msg
      return null
    }])
    return this
  }

  numeric        { numeric("Must be a number") }
  numeric(msg) {
    _validators.add(["numeric", Fn.new {|v|
      if (v == null || v == "") return null
      if (v is Num) return null
      if (!(v is String)) return msg
      var n = Num.fromString(v)
      if (n == null) return msg
      return null
    }])
    return this
  }

  range(lo, hi)       { range(lo, hi, "Must be between %(lo) and %(hi)") }
  range(lo, hi, msg) {
    _validators.add(["range", Fn.new {|v|
      if (v == null || v == "") return null
      var n = v is Num ? v : Num.fromString(v)
      if (n == null) return null
      if (n < lo || n > hi) return msg
      return null
    }])
    return this
  }

  oneOf(options)      { oneOf(options, "Invalid choice") }
  oneOf(options, msg) {
    _validators.add(["oneOf", Fn.new {|v|
      if (v == null || v == "") return null
      for (opt in options) {
        if (opt == v) return null
      }
      return msg
    }])
    return this
  }

  // Equality with another field's value. Used for confirm-password
  // style checks. `other` is the OTHER field's raw post-transform
  // value — the Form wires it in.
  matches(otherName, msg) {
    _validators.add(["matches:" + otherName, Fn.new {|v|
      // The form passes a Map of already-transformed values as the
      // second arg via the 2-param form below; see Form.validate_.
      null
    }])
    _validators.add(["matches-deferred:" + otherName, msg])
    return this
  }

  // Custom validator. `fn` takes the value; return null (ok) or
  // an error message.
  custom(fn)         { custom(fn, "Invalid") }
  custom(fn, msg) {
    _validators.add(["custom", Fn.new {|v|
      var r = fn.call(v)
      if (r == false) return msg
      if (r is String) return r
      return null
    }])
    return this
  }

  // ── used by Form.validate_ ────────────────────────────────────

  transforms_ { _transforms }
  validators_ { _validators }

  // ── helpers ───────────────────────────────────────────────────

  static trim_(v) {
    if (!(v is String)) return v
    var s = v
    var start = 0
    var end = s.count
    while (start < end && Field.isWhitespace_(s[start])) start = start + 1
    while (end > start && Field.isWhitespace_(s[end - 1])) end = end - 1
    if (start == 0 && end == s.count) return s
    if (start >= end) return ""
    return s[start..(end - 1)]
  }

  static isWhitespace_(c) {
    return c == " " || c == "\t" || c == "\n" || c == "\r"
  }

  static toLower_(s) {
    var out = ""
    var i = 0
    while (i < s.count) {
      var b = s[i].bytes[0]
      if (b >= 65 && b <= 90) {
        out = out + String.fromByte(b + 32)
      } else {
        out = out + s[i]
      }
      i = i + 1
    }
    return out
  }

  static toUpper_(s) {
    var out = ""
    var i = 0
    while (i < s.count) {
      var b = s[i].bytes[0]
      if (b >= 97 && b <= 122) {
        out = out + String.fromByte(b - 32)
      } else {
        out = out + s[i]
      }
      i = i + 1
    }
    return out
  }

  // Minimal email shape check: has exactly one '@', at least one
  // character each side, no whitespace, and a '.' after the '@'.
  // Not RFC 5322 — nobody's is. Catches typos without rejecting
  // legitimate addresses with unusual TLDs.
  static looksLikeEmail_(s) {
    if (s.count < 3) return false
    var at = -1
    var i = 0
    while (i < s.count) {
      var c = s[i]
      if (c == " " || c == "\t") return false
      if (c == "@") {
        if (at >= 0) return false   // two @
        at = i
      }
      i = i + 1
    }
    if (at <= 0 || at >= s.count - 1) return false
    // need a dot somewhere after the '@'
    var dotAfter = false
    var j = at + 1
    while (j < s.count) {
      if (s[j] == ".") {
        if (j > at + 1 && j < s.count - 1) {
          dotAfter = true
          j = s.count
        } else {
          j = j + 1
        }
      } else {
        j = j + 1
      }
    }
    return dotAfter
  }

  // http:// or https:// prefix, then at least one character.
  // Rejects javascript: and data: unambiguously.
  static looksLikeUrl_(s) {
    if (s.startsWith("http://") && s.count > 7) return true
    if (s.startsWith("https://") && s.count > 8) return true
    return false
  }
}

// ── FormResult ─────────────────────────────────────────────────────────

class FormResult {
  construct new_(data, errors, rawInput) {
    _data = data
    _errors = errors
    _raw = rawInput
  }

  valid { _errors.count == 0 }
  data { _data }
  errors { _errors }
  rawInput { _raw }   // original form input — useful for re-rendering

  errorsFor(name) {
    if (_errors.containsKey(name)) return _errors[name]
    return []
  }

  firstError(name) {
    if (!_errors.containsKey(name)) return null
    var es = _errors[name]
    if (es.count == 0) return null
    return es[0]
  }

  hasError(name) { _errors.containsKey(name) && _errors[name].count > 0 }

  // Get the cleaned value (post-transform). Falls back to raw
  // when validation failed and transforms produced nothing usable.
  valueOf(name) {
    if (_data.containsKey(name)) return _data[name]
    if (_raw.containsKey(name)) return _raw[name]
    return null
  }
}

// ── Form ───────────────────────────────────────────────────────────────

class Form {
  construct new(fields) {
    if (!(fields is List)) Fiber.abort("Form.new: fields must be a list")
    _fields = fields
  }

  fields { _fields }

  // Run transforms + validators against `params` (Map of fieldname
  // → raw value). Returns a FormResult. Missing fields land as
  // `null` pre-transform; transforms (e.g. `default_`) get to
  // handle them.
  validate(params) {
    if (!(params is Map)) Fiber.abort("Form.validate: params must be a Map")
    var data = {}
    var errors = {}
    // Pass 1: transform every field.
    for (f in _fields) {
      var v = params.containsKey(f.name) ? params[f.name] : null
      for (t in f.transforms_) v = t.call(v)
      data[f.name] = v
    }
    // Pass 2: validate, with transformed data visible so
    // cross-field `matches` can see the other value.
    for (f in _fields) {
      var msgs = []
      var i = 0
      while (i < f.validators_.count) {
        var entry = f.validators_[i]
        var kind = entry[0]
        if (kind.startsWith("matches:")) {
          var otherName = kind[8..(kind.count - 1)]
          var other = data.containsKey(otherName) ? data[otherName] : null
          var mine = data[f.name]
          // Pair (matches:X, matches-deferred:X) holds the fn + msg.
          // We wrote a no-op fn + deferred msg; evaluate here.
          if (mine != null && mine != "" && mine != other) {
            var next = f.validators_[i + 1]
            if (next != null && next[0] == "matches-deferred:" + otherName) {
              msgs.add(next[1])
            }
          }
          i = i + 2   // skip the deferred marker
        } else if (kind.startsWith("matches-deferred:")) {
          i = i + 1   // handled above; shouldn't reach here
        } else {
          var fn = entry[1]
          var msg = fn.call(data[f.name])
          if (msg != null) msgs.add(msg)
          i = i + 1
        }
      }
      if (msgs.count > 0) errors[f.name] = msgs
    }
    return FormResult.new_(data, errors, params)
  }
}
