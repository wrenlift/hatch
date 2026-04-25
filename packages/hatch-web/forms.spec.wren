import "./forms"       for Form, Field, FormResult
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- Field transforms ------------------------------------------

Test.describe("Field.trim") {
  Test.it("strips leading/trailing whitespace") {
    var f = Form.new([Field.new("x").trim])
    var r = f.validate({"x": "  hello  "})
    Expect.that(r.data["x"]).toBe("hello")
  }

  Test.it("strips tabs and newlines") {
    var f = Form.new([Field.new("x").trim])
    var r = f.validate({"x": "\t\nhello\r\n"})
    Expect.that(r.data["x"]).toBe("hello")
  }

  Test.it("empty after trim is empty string") {
    var f = Form.new([Field.new("x").trim])
    var r = f.validate({"x": "   "})
    Expect.that(r.data["x"]).toBe("")
  }

  Test.it("non-string passes through unchanged") {
    var f = Form.new([Field.new("x").trim])
    var r = f.validate({"x": 42})
    Expect.that(r.data["x"]).toBe(42)
  }
}

Test.describe("Field.lowercase / uppercase") {
  Test.it("lowercases ASCII letters") {
    var f = Form.new([Field.new("x").lowercase])
    var r = f.validate({"x": "HelloWORLD"})
    Expect.that(r.data["x"]).toBe("helloworld")
  }

  Test.it("uppercases ASCII letters") {
    var f = Form.new([Field.new("x").uppercase])
    var r = f.validate({"x": "abcXYZ"})
    Expect.that(r.data["x"]).toBe("ABCXYZ")
  }

  Test.it("non-ASCII chars pass through") {
    var f = Form.new([Field.new("x").lowercase])
    var r = f.validate({"x": "CAFÉ"})
    Expect.that(r.data["x"]).toContain("caf")
    Expect.that(r.data["x"]).toContain("É")
  }
}

Test.describe("Field.default_") {
  Test.it("fills missing values") {
    var f = Form.new([Field.new("tag").default_("untagged")])
    var r = f.validate({})
    Expect.that(r.data["tag"]).toBe("untagged")
  }

  Test.it("fills empty strings") {
    var f = Form.new([Field.new("tag").default_("none")])
    var r = f.validate({"tag": ""})
    Expect.that(r.data["tag"]).toBe("none")
  }

  Test.it("passes non-empty through") {
    var f = Form.new([Field.new("tag").default_("x")])
    var r = f.validate({"tag": "blue"})
    Expect.that(r.data["tag"]).toBe("blue")
  }
}

// --- Validators ------------------------------------------------

Test.describe("Field.required") {
  Test.it("rejects missing") {
    var f = Form.new([Field.new("email").required])
    var r = f.validate({})
    Expect.that(r.valid).toBe(false)
    Expect.that(r.firstError("email")).toContain("required")
  }

  Test.it("rejects empty string") {
    var f = Form.new([Field.new("email").required])
    var r = f.validate({"email": ""})
    Expect.that(r.valid).toBe(false)
  }

  Test.it("accepts non-empty") {
    var f = Form.new([Field.new("email").required])
    var r = f.validate({"email": "ok"})
    Expect.that(r.valid).toBe(true)
  }

  Test.it("custom message") {
    var f = Form.new([Field.new("email").required("please enter")])
    var r = f.validate({})
    Expect.that(r.firstError("email")).toBe("please enter")
  }

  Test.it("interacts with trim — whitespace-only triggers required") {
    var f = Form.new([Field.new("email").trim.required])
    var r = f.validate({"email": "   "})
    Expect.that(r.valid).toBe(false)
  }
}

Test.describe("Field.email") {
  Test.it("accepts simple addresses") {
    var f = Form.new([Field.new("e").email])
    Expect.that(f.validate({"e": "ann@example.com"}).valid).toBe(true)
    Expect.that(f.validate({"e": "a.b@c.io"}).valid).toBe(true)
  }

  Test.it("rejects obvious garbage") {
    var f = Form.new([Field.new("e").email])
    Expect.that(f.validate({"e": "notanemail"}).valid).toBe(false)
    Expect.that(f.validate({"e": "@x.com"}).valid).toBe(false)
    Expect.that(f.validate({"e": "x@"}).valid).toBe(false)
    Expect.that(f.validate({"e": "x@y"}).valid).toBe(false)           // no dot after @
    Expect.that(f.validate({"e": "a@b@c.com"}).valid).toBe(false)     // two @
    Expect.that(f.validate({"e": "a b@c.com"}).valid).toBe(false)     // space
  }

  Test.it("skipped when field is empty (required handles that)") {
    var f = Form.new([Field.new("e").email])
    Expect.that(f.validate({}).valid).toBe(true)
    Expect.that(f.validate({"e": ""}).valid).toBe(true)
  }
}

Test.describe("Field.minLength / maxLength") {
  Test.it("minLength rejects short strings") {
    var f = Form.new([Field.new("p").minLength(8)])
    Expect.that(f.validate({"p": "short"}).valid).toBe(false)
    Expect.that(f.validate({"p": "longenough"}).valid).toBe(true)
  }

  Test.it("maxLength rejects long strings") {
    var f = Form.new([Field.new("n").maxLength(5)])
    Expect.that(f.validate({"n": "abcdef"}).valid).toBe(false)
    Expect.that(f.validate({"n": "abcde"}).valid).toBe(true)
  }

  Test.it("default messages mention the bound") {
    var f = Form.new([Field.new("n").minLength(3)])
    Expect.that(f.validate({"n": "a"}).firstError("n")).toContain("3")
  }
}

Test.describe("Field.numeric / range") {
  Test.it("numeric accepts digits, rejects letters") {
    var f = Form.new([Field.new("n").numeric])
    Expect.that(f.validate({"n": "42"}).valid).toBe(true)
    Expect.that(f.validate({"n": "3.14"}).valid).toBe(true)
    Expect.that(f.validate({"n": "abc"}).valid).toBe(false)
  }

  Test.it("range accepts values in bounds") {
    var f = Form.new([Field.new("a").numeric.range(0, 100)])
    Expect.that(f.validate({"a": "50"}).valid).toBe(true)
    Expect.that(f.validate({"a": "0"}).valid).toBe(true)
    Expect.that(f.validate({"a": "100"}).valid).toBe(true)
    Expect.that(f.validate({"a": "101"}).valid).toBe(false)
    Expect.that(f.validate({"a": "-1"}).valid).toBe(false)
  }
}

Test.describe("Field.oneOf") {
  Test.it("accepts listed values") {
    var f = Form.new([Field.new("role").oneOf(["user", "admin", "guest"])])
    Expect.that(f.validate({"role": "admin"}).valid).toBe(true)
    Expect.that(f.validate({"role": "guest"}).valid).toBe(true)
  }

  Test.it("rejects unlisted") {
    var f = Form.new([Field.new("role").oneOf(["user", "admin"])])
    Expect.that(f.validate({"role": "root"}).valid).toBe(false)
  }
}

Test.describe("Field.matches") {
  Test.it("ok when both match") {
    var f = Form.new([
      Field.new("pw").required,
      Field.new("pw2").matches("pw", "Passwords must match")
    ])
    var r = f.validate({"pw": "secret", "pw2": "secret"})
    Expect.that(r.valid).toBe(true)
  }

  Test.it("error when different") {
    var f = Form.new([
      Field.new("pw").required,
      Field.new("pw2").matches("pw", "Passwords must match")
    ])
    var r = f.validate({"pw": "secret", "pw2": "oops"})
    Expect.that(r.valid).toBe(false)
    Expect.that(r.firstError("pw2")).toBe("Passwords must match")
  }
}

Test.describe("Field.custom") {
  Test.it("string return sets error message") {
    var f = Form.new([
      Field.new("n").custom(Fn.new {|v| v == "bad" ? "No bad allowed" : null })
    ])
    Expect.that(f.validate({"n": "ok"}).valid).toBe(true)
    var r = f.validate({"n": "bad"})
    Expect.that(r.valid).toBe(false)
    Expect.that(r.firstError("n")).toBe("No bad allowed")
  }

  Test.it("false return uses default msg") {
    var f = Form.new([
      Field.new("x").custom(Fn.new {|v| v == "ok" })
    ])
    Expect.that(f.validate({"x": "ok"}).valid).toBe(true)
    Expect.that(f.validate({"x": "nope"}).valid).toBe(false)
  }
}

// --- FormResult shape -----------------------------------------

Test.describe("FormResult") {
  Test.it("collects multiple errors per field in order") {
    var f = Form.new([
      Field.new("n").numeric.range(0, 10)
    ])
    // "abc" trips both numeric AND range (range coerces string
    // via Num.fromString, which returns null → passes… let's
    // use a case where TWO validators actually both fail):
    // minLength(5) + email both fail on "x@y"
    var f2 = Form.new([Field.new("e").minLength(10).email])
    var r = f2.validate({"e": "x@y"})
    Expect.that(r.errorsFor("e").count > 1).toBe(true)
  }

  Test.it("errorsFor missing field returns empty list") {
    var f = Form.new([Field.new("x").required])
    var r = f.validate({"x": "ok"})
    Expect.that(r.errorsFor("nothing").count).toBe(0)
  }

  Test.it("valueOf returns cleaned value on success") {
    var f = Form.new([Field.new("e").trim.lowercase.email])
    var r = f.validate({"e": "  Ann@Example.com  "})
    Expect.that(r.valueOf("e")).toBe("ann@example.com")
    Expect.that(r.valid).toBe(true)
  }

  Test.it("rawInput preserves the original map") {
    var f = Form.new([Field.new("x").required])
    var raw = {"x": "", "other": "kept"}
    var r = f.validate(raw)
    Expect.that(r.rawInput["other"]).toBe("kept")
  }
}

// --- Realistic form -------------------------------------------

Test.describe("realistic signup form") {
  var signup = Form.new([
    Field.new("email").trim.lowercase
                      .required("Email is required")
                      .email("Looks invalid"),
    Field.new("password").required("Password is required")
                         .minLength(8, "At least 8 characters"),
    Field.new("passwordConfirm").matches("password", "Passwords must match"),
    Field.new("name").trim.maxLength(80, "Name too long"),
    Field.new("role").default_("user").oneOf(["user", "admin"])
  ])

  Test.it("accepts a valid signup") {
    var r = signup.validate({
      "email": "  Ann@Example.com  ",
      "password": "correct horse",
      "passwordConfirm": "correct horse",
      "name": "Ann"
    })
    Expect.that(r.valid).toBe(true)
    Expect.that(r.data["email"]).toBe("ann@example.com")
    Expect.that(r.data["role"]).toBe("user")
  }

  Test.it("reports a fistful of errors on bad input") {
    var r = signup.validate({
      "email": "not-an-email",
      "password": "123",
      "passwordConfirm": "456",
      "name": ""
    })
    Expect.that(r.valid).toBe(false)
    Expect.that(r.hasError("email")).toBe(true)
    Expect.that(r.hasError("password")).toBe(true)
    Expect.that(r.hasError("passwordConfirm")).toBe(true)
  }
}

Test.run()
