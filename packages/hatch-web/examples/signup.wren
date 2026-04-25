// @hatch:web — signup + login demo, exercising Phase 1-3 surface.
//
//   wlift --mode interpreter signup.wren
//   open http://127.0.0.1:3000
//
// What this stitches together:
//   - Form schema with transforms + validators (./forms)
//   - argon2id password hashing (@hatch:crypto Password)
//   - Signed-cookie session (./web Session)
//   - CSS combinator with per-request fragment scope (./css Css)
//   - Flash notices across redirects
//   - htmx-free progressive enhancement — the form posts work without JS
//
// Not persisted — users live in an in-memory Map. Swap for an
// ORM-backed store when Phase 5 lands.

import "../web"       for App, Form, Field, Response, Session, Flash, Csrf
import "../css"       for Css
import "@hatch:crypto" for Password

var app = App.new()
app.use(Session.cookie("demo-secret-change-me"))
app.use(Csrf.middleware)

var users = {}       // email -> { hash, name }

var signupForm = Form.new([
  Field.new("email").trim.lowercase
                    .required("Email is required")
                    .email("Looks invalid"),
  Field.new("password").required("Password is required")
                       .minLength(8, "At least 8 characters"),
  Field.new("name").trim.maxLength(80, "Too long")
])

var loginForm = Form.new([
  Field.new("email").trim.lowercase.required.email,
  Field.new("password").required
])

var page = Css.tw("font-sans max-w-md mx-auto my-10 p-6 bg-white rounded-lg shadow")
var heading = Css.tw("text-2xl font-bold text-gray-900 mb-4")
var label = Css.tw("block text-sm font-medium text-gray-700 mb-1")
var input = Css.tw("w-full px-3 py-2 border border-gray-300 rounded")
              .focus("border-blue-500")
var errorText = Css.tw("text-sm text-red-600 mt-1")
var btn = Css.tw("w-full bg-blue-500 text-white px-4 py-2 rounded font-semibold mt-4")
             .hover("bg-blue-600")
var flashNotice = Css.tw("p-3 bg-green-100 text-green-800 rounded mb-4")
var nav = Css.tw("text-sm text-gray-600 mt-4 text-center")

app.get("/") {|req|
  req.style(page)
  req.style(heading)
  req.style(flashNotice)
  req.style(nav)
  var user = req.session.containsKey("email") ? req.session["email"] : null
  var notice = ""
  if (req.flash.containsKey("notice")) {
    notice = "<div class='%(flashNotice.className)'>" + req.flash["notice"] + "</div>"
  }
  var body = ""
  if (user == null) {
    body = "<p>You're signed out. " +
           "<a href='/signup'>Sign up</a> or <a href='/login'>log in</a>.</p>"
  } else {
    body = "<p>Hi <strong>" + user + "</strong>!</p>" +
           "<p><a href='/logout'>Log out</a></p>"
  }
  return req.globalSheet.styleTag + req.fragmentSheet.styleTag +
    "<div class='" + page.className + "'>" +
    "<h1 class='" + heading.className + "'>@hatch:web demo</h1>" +
    notice +
    body +
    "</div>"
}

app.get("/signup") {|req| renderSignup.call(req, null) }

app.post("/signup") {|req|
  var r = req.validate(signupForm)
  if (!r.valid) return renderSignup.call(req, r)
  var email = r.data["email"]
  if (users.containsKey(email)) {
    req.setFlash("notice", "That email is already registered — try logging in.")
    return Response.redirect("/login")
  }
  users[email] = {
    "hash": Password.hash(r.data["password"]),
    "name": r.data["name"]
  }
  req.session["email"] = email
  req.setFlash("notice", "Welcome, " + email + "!")
  return Response.redirect("/")
}

app.get("/login") {|req| renderLogin.call(req, null) }

app.post("/login") {|req|
  var r = req.validate(loginForm)
  if (!r.valid) return renderLogin.call(req, r)
  var email = r.data["email"]
  if (!users.containsKey(email) ||
      !Password.verify(r.data["password"], users[email]["hash"])) {
    return renderLogin.call(req, loginFailure_.call(r, email))
  }
  req.session["email"] = email
  req.setFlash("notice", "Welcome back, " + email + "!")
  return Response.redirect("/")
}

app.get("/logout") {|req|
  req.session.remove("email")
  req.setFlash("notice", "Signed out.")
  return Response.redirect("/")
}

// ── helpers ──────────────────────────────────────────────────────────

var loginFailure_ = Fn.new {|result, email|
  // Forge a FormResult-ish object that the template can iterate
  // for error display. We clone the form shape and seed a generic
  // error on the password field so the UI doesn't leak which of
  // (email, password) was wrong.
  var r = loginForm.validate({"email": email, "password": "__loginfail__"})
  if (!r.errors.containsKey("password")) r.errors["password"] = []
  r.errors["password"].add("Email or password is incorrect")
  return r
}

var renderFormShell_ = Fn.new {|req, title, action, fields, result|
  req.style(page)
  req.style(heading)
  req.style(label)
  req.style(input)
  req.style(errorText)
  req.style(btn)
  req.style(nav)
  var rows = ""
  for (f in fields) {
    var name = f[0]
    var labelText = f[1]
    var type = f[2]
    var value = result != null && result.rawInput.containsKey(name) ?
      escape_.call(result.rawInput[name]) : ""
    var errors = ""
    if (result != null && result.hasError(name)) {
      for (msg in result.errorsFor(name)) {
        errors = errors + "<div class='" + errorText.className + "'>" + msg + "</div>"
      }
    }
    rows = rows +
      "<div style='margin-top: 1rem;'>" +
      "<label class='" + label.className + "' for='" + name + "'>" + labelText + "</label>" +
      "<input class='" + input.className + "' type='" + type + "' name='" + name +
      "' id='" + name + "' value='" + value + "'>" +
      errors +
      "</div>"
  }
  return req.globalSheet.styleTag + req.fragmentSheet.styleTag +
    "<div class='" + page.className + "'>" +
    "<h1 class='" + heading.className + "'>" + title + "</h1>" +
    "<form method='POST' action='" + action + "'>" +
    Csrf.field(req) +
    rows +
    "<button class='" + btn.className + "' type='submit'>" + title + "</button>" +
    "</form>" +
    "<div class='" + nav.className + "'><a href='/'>Home</a></div>" +
    "</div>"
}

var escape_ = Fn.new {|s|
  if (s == null) return ""
  if (!(s is String)) return s.toString
  // Minimal HTML escape — enough so echoed input doesn't break out
  // of the value attribute. Tweak when you add rich input types.
  var out = ""
  var i = 0
  while (i < s.count) {
    var c = s[i]
    if (c == "&") {
      out = out + "&amp;"
    } else if (c == "<") {
      out = out + "&lt;"
    } else if (c == ">") {
      out = out + "&gt;"
    } else if (c == "\"") {
      out = out + "&quot;"
    } else if (c == "'") {
      out = out + "&#39;"
    } else {
      out = out + c
    }
    i = i + 1
  }
  return out
}

var renderSignup = Fn.new {|req, result|
  renderFormShell_.call(req, "Sign up", "/signup", [
    ["email",    "Email",    "email"],
    ["password", "Password", "password"],
    ["name",     "Your name","text"]
  ], result)
}

var renderLogin = Fn.new {|req, result|
  renderFormShell_.call(req, "Log in", "/login", [
    ["email",    "Email",    "email"],
    ["password", "Password", "password"]
  ], result)
}

app.listen("127.0.0.1:3000")
