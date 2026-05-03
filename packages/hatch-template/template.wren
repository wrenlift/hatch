/// `@hatch:template`: Jinja / Twig-style templating for HTML
/// and XML.
///
/// ```wren
/// import "@hatch:template" for Template, Hx
///
/// var tpl = Template.parse("<h1>Hello {{ name }}</h1>")
/// tpl.render({ "name": "world" })          //= "<h1>Hello world</h1>"
/// ```
///
/// ## Syntax
///
/// | Form                   | Meaning                                                |
/// |------------------------|--------------------------------------------------------|
/// | `{{ expr }}`           | Interpolation (HTML-escaped).                          |
/// | `{{{ expr }}}`         | Raw interpolation (unescaped).                         |
/// | `{% if expr %}`        | Conditional (`elif` / `else` / `endif`).               |
/// | `{% for x in expr %}`  | Loop over a sequence (`endfor`).                       |
/// | `{% slot name %}`      | Named slot with default body (`endslot`).              |
/// | `{% fragment name %}`  | Addressable partial for htmx responses (`endfragment`). |
/// | `{% set x = expr %}`   | Bind a variable in current scope.                      |
/// | `{% include "name" %}` | Render a registered component by name.                 |
/// | `{# comment #}`        | Stripped at parse time.                                |
///
/// ## Expressions
///
/// - Paths: `user.name`, `items[0]`, `ctx["key"]`.
/// - Literals: `42`, `1.5`, `"str"`, `'str'`, `true`, `false`, `null`.
/// - Comparisons: `==` `!=` `<` `<=` `>` `>=`.
/// - Booleans: `and` / `or` / `not`.
/// - Filters: `{{ x | upper }}` / `{{ x | default("-") }}`.
/// - Builtins: `escape`, `raw`, `upper`, `lower`, `default`,
///   `length`, `join`.
///
/// ## htmx
///
/// - `tpl.renderFragment("name", ctx)` renders a
///   `{% fragment %}` block only.
/// - `ctx["#hx"] = { "request": true }` is exposed as `hx` in
///   templates.
/// - `Hx.response(body).trigger("x")` builds `HX-*` response
///   headers.

class TemplateError {
  construct new(msg) { _msg = msg }
  message { _msg }
  toString { "TemplateError: " + _msg }
}

// --- Lexer -----------------------------------------------------------------

class Lex_ {
  construct new(src) {
    _src = src
    _pos = 0
    _out = []
    _buf = ""
  }

  static scan(src) {
    var l = Lex_.new(src)
    l.run()
    return l.tokens
  }

  tokens { _out }

  run() {
    while (_pos < _src.count) {
      var ch = _src[_pos]
      if (ch == "{" && _pos + 1 < _src.count) {
        var n = _src[_pos + 1]
        if (n == "{") {
          flushText_()
          interp_()
          continue
        } else if (n == "%") {
          flushText_()
          stmt_()
          continue
        } else if (n == "#") {
          flushText_()
          comment_()
          continue
        }
      }
      _buf = _buf + ch
      _pos = _pos + 1
    }
    flushText_()
  }

  flushText_() {
    if (_buf.count > 0) {
      _out.add(["text", _buf])
      _buf = ""
    }
  }

  interp_() {
    _pos = _pos + 2
    var raw = false
    if (_pos < _src.count && _src[_pos] == "{") {
      raw = true
      _pos = _pos + 1
    }
    var start = _pos
    while (_pos < _src.count) {
      if (raw && _pos + 2 < _src.count && _src[_pos] == "}" &&
          _src[_pos + 1] == "}" && _src[_pos + 2] == "}") {
        var inner = _src[start..._pos]
        _out.add(["interp", inner, true])
        _pos = _pos + 3
        return
      } else if (!raw && _pos + 1 < _src.count && _src[_pos] == "}" &&
                 _src[_pos + 1] == "}") {
        var inner = _src[start..._pos]
        _out.add(["interp", inner, false])
        _pos = _pos + 2
        return
      }
      _pos = _pos + 1
    }
    Fiber.abort("unterminated {{ ... }}")
  }

  stmt_() {
    _pos = _pos + 2
    var trimLeft = false
    if (_pos < _src.count && _src[_pos] == "-") {
      trimLeft = true
      _pos = _pos + 1
    }
    // Trim trailing whitespace on preceding text if `{%-`.
    if (trimLeft && _out.count > 0 && _out[-1][0] == "text") {
      _out[-1][1] = rtrim_(_out[-1][1])
    }
    var start = _pos
    while (_pos < _src.count) {
      if (_pos + 1 < _src.count && _src[_pos] == "-" && _src[_pos + 1] == "%" &&
          _pos + 2 < _src.count && _src[_pos + 2] == "}") {
        var inner = _src[start..._pos]
        _out.add(["stmt", inner.trim(), "trimRight"])
        _pos = _pos + 3
        skipLeadingWs_()
        return
      } else if (_pos + 1 < _src.count && _src[_pos] == "%" && _src[_pos + 1] == "}") {
        var inner = _src[start..._pos]
        _out.add(["stmt", inner.trim(), null])
        _pos = _pos + 2
        return
      }
      _pos = _pos + 1
    }
    Fiber.abort("unterminated {% ... %}")
  }

  skipLeadingWs_() {
    while (_pos < _src.count) {
      var c = _src[_pos]
      if (c == " " || c == "\t" || c == "\n" || c == "\r") {
        _pos = _pos + 1
      } else {
        break
      }
    }
  }

  comment_() {
    _pos = _pos + 2
    while (_pos + 1 < _src.count) {
      if (_src[_pos] == "#" && _src[_pos + 1] == "}") {
        _pos = _pos + 2
        return
      }
      _pos = _pos + 1
    }
    Fiber.abort("unterminated {# ... #}")
  }

  rtrim_(s) {
    var i = s.count - 1
    while (i >= 0) {
      var c = s[i]
      if (c == " " || c == "\t" || c == "\n" || c == "\r") {
        i = i - 1
      } else {
        break
      }
    }
    if (i < 0) return ""
    return s[0..i]
  }
}

// --- Expression parser -----------------------------------------------------
//
// Recursive descent over a string cursor. Grammar:
//   or     := and ('or' and)*
//   and    := not ('and' not)*
//   not    := 'not' not | cmp
//   cmp    := filter (cmpop filter)?
//   filter := primary ('|' ident ('(' args ')')?)*
//   primary := literal | path | '(' or ')'
//   path    := ident ('.' ident | '[' or ']')*

class ExprParse_ {
  construct new(src) {
    _src = src
    _pos = 0
  }

  static parse(src) {
    var p = ExprParse_.new(src)
    var e = p.parseOr_()
    p.skipWs_()
    if (p.pos_ < src.count) {
      Fiber.abort("unexpected trailing input in expression: " + src[p.pos_..-1])
    }
    return e
  }

  pos_ { _pos }

  skipWs_() {
    while (_pos < _src.count) {
      var c = _src[_pos]
      if (c == " " || c == "\t" || c == "\n" || c == "\r") {
        _pos = _pos + 1
      } else {
        break
      }
    }
  }

  peek_(s) {
    skipWs_()
    if (_pos + s.count > _src.count) return false
    return _src[_pos..._pos + s.count] == s
  }

  // Like peek_ but also checks that the match is a whole word
  // (followed by whitespace, EOS, or a punctuator).
  peekWord_(w) {
    if (!peek_(w)) return false
    var after = _pos + w.count
    if (after >= _src.count) return true
    var c = _src[after]
    return isIdentCh_(c) == false
  }

  eat_(s) {
    if (peek_(s)) {
      _pos = _pos + s.count
      return true
    }
    return false
  }

  eatWord_(w) {
    if (peekWord_(w)) {
      _pos = _pos + w.count
      return true
    }
    return false
  }

  parseOr_() {
    var left = parseAnd_()
    while (eatWord_("or")) {
      var right = parseAnd_()
      left = ["or", left, right]
    }
    return left
  }

  parseAnd_() {
    var left = parseNot_()
    while (eatWord_("and")) {
      var right = parseNot_()
      left = ["and", left, right]
    }
    return left
  }

  parseNot_() {
    if (eatWord_("not")) return ["not", parseNot_()]
    return parseCmp_()
  }

  parseCmp_() {
    var left = parseFilter_()
    skipWs_()
    var ops = ["==", "!=", "<=", ">=", "<", ">"]
    for (op in ops) {
      if (eat_(op)) {
        var right = parseFilter_()
        return ["cmp", op, left, right]
      }
    }
    return left
  }

  parseFilter_() {
    var e = parsePrimary_()
    while (true) {
      skipWs_()
      if (!eat_("|")) break
      skipWs_()
      var name = parseIdent_()
      var args = []
      skipWs_()
      if (eat_("(")) {
        skipWs_()
        if (!peek_(")")) {
          args.add(parseOr_())
          skipWs_()
          while (eat_(",")) {
            skipWs_()
            args.add(parseOr_())
            skipWs_()
          }
        }
        if (!eat_(")")) Fiber.abort("expected ')' in filter args")
      }
      e = ["filter", e, name, args]
    }
    return e
  }

  parsePrimary_() {
    skipWs_()
    if (_pos >= _src.count) Fiber.abort("expected expression")
    var c = _src[_pos]
    if (c == "(") {
      _pos = _pos + 1
      var e = parseOr_()
      skipWs_()
      if (!eat_(")")) Fiber.abort("expected ')'")
      return e
    }
    if (c == "\"" || c == "'") return parseString_()
    if (isDigit_(c) || (c == "-" && _pos + 1 < _src.count && isDigit_(_src[_pos + 1]))) {
      return parseNumber_()
    }
    if (isIdentStart_(c)) {
      var name = parseIdent_()
      if (name == "true") return ["lit", true]
      if (name == "false") return ["lit", false]
      if (name == "null") return ["lit", null]
      return parsePath_(name)
    }
    Fiber.abort("unexpected character in expression: '" + c + "'")
  }

  parsePath_(base) {
    var steps = []
    while (true) {
      skipWs_()
      if (eat_(".")) {
        skipWs_()
        var name = parseIdent_()
        steps.add(["dot", name])
      } else if (eat_("[")) {
        skipWs_()
        var idx = parseOr_()
        skipWs_()
        if (!eat_("]")) Fiber.abort("expected ']'")
        steps.add(["idx", idx])
      } else {
        break
      }
    }
    return ["path", base, steps]
  }

  parseIdent_() {
    skipWs_()
    var start = _pos
    if (_pos >= _src.count || !isIdentStart_(_src[_pos])) {
      Fiber.abort("expected identifier")
    }
    while (_pos < _src.count && isIdentCh_(_src[_pos])) _pos = _pos + 1
    return _src[start..._pos]
  }

  parseString_() {
    var quote = _src[_pos]
    _pos = _pos + 1
    var out = ""
    while (_pos < _src.count && _src[_pos] != quote) {
      var c = _src[_pos]
      if (c == "\\" && _pos + 1 < _src.count) {
        var n = _src[_pos + 1]
        if (n == "n") { out = out + "\n" }
        else if (n == "t") { out = out + "\t" }
        else if (n == "r") { out = out + "\r" }
        else if (n == "\\") { out = out + "\\" }
        else if (n == "\"") { out = out + "\"" }
        else if (n == "'") { out = out + "'" }
        else { out = out + n }
        _pos = _pos + 2
      } else {
        out = out + c
        _pos = _pos + 1
      }
    }
    if (_pos >= _src.count) Fiber.abort("unterminated string in expression")
    _pos = _pos + 1
    return ["lit", out]
  }

  parseNumber_() {
    var start = _pos
    if (_src[_pos] == "-") _pos = _pos + 1
    while (_pos < _src.count && isDigit_(_src[_pos])) _pos = _pos + 1
    if (_pos < _src.count && _src[_pos] == "." &&
        _pos + 1 < _src.count && isDigit_(_src[_pos + 1])) {
      _pos = _pos + 1
      while (_pos < _src.count && isDigit_(_src[_pos])) _pos = _pos + 1
    }
    return ["lit", Num.fromString(_src[start..._pos])]
  }

  isDigit_(c) { c.bytes[0] >= 48 && c.bytes[0] <= 57 }
  isIdentStart_(c) {
    var b = c.bytes[0]
    return (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
  }
  isIdentCh_(c) {
    var b = c.bytes[0]
    return (b >= 65 && b <= 90) || (b >= 97 && b <= 122) ||
           (b >= 48 && b <= 57) || b == 95
  }
}

// --- Statement / body parser -----------------------------------------------
//
// Consumes the lexer's token list and produces an AST: a list of nodes.
// Node shapes:
//   ["text", string]
//   ["interp", exprAst, raw]
//   ["if", [[cond, body], ...], elseBody|null]
//   ["for", varName, exprAst, body]
//   ["slot", name, defaultBody]
//   ["fragment", name, body]
//   ["set", name, exprAst]
//   ["include", name]

class Parse_ {
  construct new(tokens) {
    _toks = tokens
    _pos = 0
  }

  static parse(tokens) {
    var p = Parse_.new(tokens)
    var body = p.parseBody_([])
    if (p.pos_ < tokens.count) {
      Fiber.abort("unexpected stray directive: " + p.peekStmt_())
    }
    return body
  }

  pos_ { _pos }

  peekStmt_() {
    if (_pos >= _toks.count) return ""
    return _toks[_pos][1]
  }

  parseBody_(endWords) {
    var body = []
    while (_pos < _toks.count) {
      var t = _toks[_pos]
      if (t[0] == "text") {
        body.add(["text", t[1]])
        _pos = _pos + 1
      } else if (t[0] == "interp") {
        body.add(["interp", ExprParse_.parse(t[1]), t[2]])
        _pos = _pos + 1
      } else if (t[0] == "stmt") {
        var first = firstWord_(t[1])
        if (endWords.contains(first)) return body
        _pos = _pos + 1
        body.add(parseStmt_(first, t[1]))
      } else {
        _pos = _pos + 1
      }
    }
    return body
  }

  parseStmt_(kw, raw) {
    if (kw == "if") return parseIf_(raw)
    if (kw == "for") return parseFor_(raw)
    if (kw == "slot") return parseSlot_(raw)
    if (kw == "fragment") return parseFragment_(raw)
    if (kw == "set") return parseSet_(raw)
    if (kw == "include") return parseInclude_(raw)
    if (kw == "extends") return parseExtends_(raw)
    if (kw == "block") return parseBlock_(raw)
    if (kw == "embed") return parseEmbed_(raw)
    if (kw == "call") return parseCall_(raw)
    Fiber.abort("unknown directive: '" + kw + "'")
  }

  parseExtends_(raw) {
    var arg = rest_("extends", raw).trim()
    if (arg.count >= 2 && (arg[0] == "\"" || arg[0] == "'") &&
        arg[-1] == arg[0]) {
      arg = arg[1..-2]
    }
    if (arg == "") Fiber.abort("extends: template name required")
    return ["extends", arg]
  }

  parseBlock_(raw) {
    var name = rest_("block", raw).trim()
    if (name == "") Fiber.abort("block: name required")
    var body = parseBody_(["endblock"])
    if (_pos >= _toks.count || _toks[_pos][0] != "stmt" ||
        firstWord_(_toks[_pos][1]) != "endblock") {
      Fiber.abort("unterminated {% block %}")
    }
    _pos = _pos + 1
    return ["block", name, body]
  }

  parseIf_(raw) {
    var cond = ExprParse_.parse(rest_("if", raw))
    var body = parseBody_(["elif", "else", "endif"])
    var branches = [[cond, body]]
    var elseBody = null
    while (_pos < _toks.count) {
      var t = _toks[_pos]
      if (t[0] != "stmt") Fiber.abort("expected endif")
      var kw = firstWord_(t[1])
      if (kw == "elif") {
        _pos = _pos + 1
        var c = ExprParse_.parse(rest_("elif", t[1]))
        var b = parseBody_(["elif", "else", "endif"])
        branches.add([c, b])
      } else if (kw == "else") {
        _pos = _pos + 1
        elseBody = parseBody_(["endif"])
      } else if (kw == "endif") {
        _pos = _pos + 1
        return ["if", branches, elseBody]
      } else {
        Fiber.abort("expected elif/else/endif, got '" + kw + "'")
      }
    }
    Fiber.abort("unterminated {% if %}")
  }

  parseFor_(raw) {
    var tail = rest_("for", raw)
    // Format: "<var> in <expr>"
    var inIdx = findInKeyword_(tail)
    if (inIdx < 0) Fiber.abort("for: expected '<var> in <expr>'")
    var varName = tail[0...inIdx].trim()
    var exprStr = tail[inIdx + 2..-1].trim()
    var body = parseBody_(["endfor"])
    if (_pos >= _toks.count || _toks[_pos][0] != "stmt" ||
        firstWord_(_toks[_pos][1]) != "endfor") {
      Fiber.abort("unterminated {% for %}")
    }
    _pos = _pos + 1
    return ["for", varName, ExprParse_.parse(exprStr), body]
  }

  parseSlot_(raw) {
    var tail = rest_("slot", raw).trim()
    if (tail == "") Fiber.abort("slot: name required")
    var np = splitNameTail_(tail)
    var name = np[0]
    var rest = np[1]
    var withBindings = []
    if (rest.count > 0) {
      if (!rest.startsWith("with")) {
        Fiber.abort("slot: expected 'with { ... }', got '" + rest + "'")
      }
      withBindings = parseObjectBindings_(rest[4..-1].trim())
    }
    var body = parseBody_(["endslot"])
    if (_pos >= _toks.count || _toks[_pos][0] != "stmt" ||
        firstWord_(_toks[_pos][1]) != "endslot") {
      Fiber.abort("unterminated {% slot %}")
    }
    _pos = _pos + 1
    return ["slot", name, withBindings, body]
  }

  parseEmbed_(raw) {
    var tail = rest_("embed", raw).trim()
    // Name may be quoted or bare.
    if (tail.count >= 2 && (tail[0] == "\"" || tail[0] == "'")) {
      var q = tail[0]
      var end = tail.indexOf(q, 1)
      if (end < 0) Fiber.abort("embed: unterminated quoted name")
      var name = tail[1...end]
      var rest = tail[end + 1..-1].trim()
      return parseEmbedTail_(name, rest)
    }
    var np = splitNameTail_(tail)
    return parseEmbedTail_(np[0], np[1])
  }

  parseEmbedTail_(name, rest) {
    if (name == "") Fiber.abort("embed: name required")
    var withArgs = []
    if (rest.count > 0) {
      if (!rest.startsWith("with")) {
        Fiber.abort("embed: expected 'with { ... }' or end, got '" + rest + "'")
      }
      withArgs = parseObjectBindings_(rest[4..-1].trim())
    }
    // Body: whitespace text + {% fill %}s until {% endembed %}.
    var fills = []
    while (_pos < _toks.count) {
      var t = _toks[_pos]
      if (t[0] == "text") {
        if (t[1].trim().count > 0) {
          Fiber.abort("embed: only {% fill %} blocks allowed in body")
        }
        _pos = _pos + 1
      } else if (t[0] == "stmt") {
        var kw = firstWord_(t[1])
        if (kw == "endembed") {
          _pos = _pos + 1
          return ["embed", name, withArgs, fills]
        }
        if (kw == "fill") {
          _pos = _pos + 1
          fills.add(parseFillBody_(t[1]))
        } else {
          Fiber.abort("embed: unexpected directive '" + kw + "'")
        }
      } else {
        Fiber.abort("embed: {{ ... }} not allowed outside {% fill %}")
      }
    }
    Fiber.abort("unterminated {% embed %}")
  }

  parseFillBody_(raw) {
    var name = rest_("fill", raw).trim()
    if (name == "") Fiber.abort("fill: name required")
    var body = parseBody_(["endfill"])
    if (_pos >= _toks.count || _toks[_pos][0] != "stmt" ||
        firstWord_(_toks[_pos][1]) != "endfill") {
      Fiber.abort("unterminated {% fill %}")
    }
    _pos = _pos + 1
    return ["fill", name, body]
  }

  // Shared helper: peel a leading identifier off `tail`, return
  // [name, rest] with leading whitespace trimmed off `rest`.
  splitNameTail_(tail) {
    var i = 0
    while (i < tail.count) {
      var c = tail[i]
      if (c == " " || c == "\t") break
      i = i + 1
    }
    return [tail[0...i], tail[i..-1].trim()]
  }

  // Parse "{ k1: expr, k2: expr }" into a list of [key, exprAst]
  // pairs. Commas and colons inside expressions are respected via
  // paren/bracket depth tracking.
  parseObjectBindings_(s) {
    s = s.trim()
    if (s.count == 0 || s[0] != "{") Fiber.abort("expected '{' in bindings")
    if (s[-1] != "}") Fiber.abort("expected '}' in bindings")
    var inner = s[1..-2].trim()
    var out = []
    if (inner.count == 0) return out
    for (part in splitTopLevelCommas_(inner)) {
      var colon = findTopLevelChar_(part, ":")
      if (colon < 0) Fiber.abort("expected 'key: expr' in bindings: '" + part + "'")
      var k = part[0...colon].trim()
      var v = part[colon + 1..-1].trim()
      out.add([k, ExprParse_.parse(v)])
    }
    return out
  }

  splitTopLevelCommas_(s) {
    var out = []
    var depth = 0
    var start = 0
    var i = 0
    while (i < s.count) {
      var c = s[i]
      if (c == "(" || c == "[" || c == "{") {
        depth = depth + 1
      } else if (c == ")" || c == "]" || c == "}") {
        depth = depth - 1
      } else if (c == "," && depth == 0) {
        out.add(s[start...i])
        start = i + 1
      }
      i = i + 1
    }
    if (start < s.count) out.add(s[start..-1])
    return out
  }

  findTopLevelChar_(s, ch) {
    var depth = 0
    var i = 0
    while (i < s.count) {
      var c = s[i]
      if (c == "(" || c == "[" || c == "{") depth = depth + 1
      else if (c == ")" || c == "]" || c == "}") depth = depth - 1
      else if (c == ch && depth == 0) return i
      i = i + 1
    }
    return -1
  }

  parseFragment_(raw) {
    var tail = rest_("fragment", raw).trim()
    if (tail == "") Fiber.abort("fragment: name required")
    // `{% fragment foo %}`     → bare, renders inline
    // `{% fragment foo() %}`   → parameterized (even with 0 args), callable only
    // `{% fragment foo(a, b) %}` → parameterized with args
    var paren = tail.indexOf("(")
    var name = ""
    var params = null
    if (paren < 0) {
      name = tail
    } else {
      name = tail[0...paren].trim()
      if (tail[-1] != ")") Fiber.abort("fragment: unterminated parameter list")
      params = []
      var inner = tail[paren + 1...-1].trim()
      if (inner.count > 0) {
        for (part in splitTopLevelCommas_(inner)) {
          params.add(part.trim())
        }
      }
    }
    if (name == "") Fiber.abort("fragment: name required")
    var body = parseBody_(["endfragment"])
    if (_pos >= _toks.count || _toks[_pos][0] != "stmt" ||
        firstWord_(_toks[_pos][1]) != "endfragment") {
      Fiber.abort("unterminated {% fragment %}")
    }
    _pos = _pos + 1
    return ["fragment", name, params, body]
  }

  parseCall_(raw) {
    var tail = rest_("call", raw).trim()
    var paren = tail.indexOf("(")
    if (paren < 0 || tail[-1] != ")") {
      Fiber.abort("call: expected 'name(args...)'")
    }
    var name = tail[0...paren].trim()
    if (name == "") Fiber.abort("call: name required")
    var inner = tail[paren + 1...-1].trim()
    var argExprs = []
    if (inner.count > 0) {
      for (part in splitTopLevelCommas_(inner)) {
        argExprs.add(ExprParse_.parse(part.trim()))
      }
    }
    var body = parseBody_(["endcall"])
    if (_pos >= _toks.count || _toks[_pos][0] != "stmt" ||
        firstWord_(_toks[_pos][1]) != "endcall") {
      Fiber.abort("unterminated {% call %}")
    }
    _pos = _pos + 1
    return ["call", name, argExprs, body]
  }

  parseSet_(raw) {
    var tail = rest_("set", raw)
    var eq = tail.indexOf("=")
    if (eq < 0) Fiber.abort("set: expected '<name> = <expr>'")
    var name = tail[0...eq].trim()
    var exprStr = tail[eq + 1..-1].trim()
    return ["set", name, ExprParse_.parse(exprStr)]
  }

  parseInclude_(raw) {
    var arg = rest_("include", raw).trim()
    // Accept either a bare identifier or a quoted name.
    if (arg.count >= 2 && (arg[0] == "\"" || arg[0] == "'") &&
        arg[-1] == arg[0]) {
      arg = arg[1..-2]
    }
    return ["include", arg]
  }

  firstWord_(s) {
    var i = 0
    while (i < s.count) {
      var c = s[i]
      if (c == " " || c == "\t") break
      i = i + 1
    }
    return s[0...i]
  }

  rest_(kw, s) {
    // kw guaranteed present at start.
    var n = kw.count
    if (s.count <= n) return ""
    return s[n..-1]
  }

  // Find ` in ` as a keyword (not inside an identifier).
  findInKeyword_(s) {
    var i = 0
    while (i + 4 <= s.count) {
      if (s[i] == " " && s[i + 1] == "i" && s[i + 2] == "n" &&
          (i + 3 >= s.count || s[i + 3] == " ")) {
        return i + 1
      }
      i = i + 1
    }
    return -1
  }
}

// --- Renderer --------------------------------------------------------------

class Scope_ {
  construct root(ctx) {
    _ctx = ctx
    _parent = null
  }
  construct child(parent) {
    _ctx = {}
    _parent = parent
  }

  set(name, value) { _ctx[name] = value }

  lookup(name) {
    if (_ctx.containsKey(name)) return _ctx[name]
    if (_parent != null) return _parent.lookup(name)
    return null
  }

  has(name) {
    if (_ctx.containsKey(name)) return true
    if (_parent != null) return _parent.has(name)
    return false
  }
}

// Internal: wraps a {% fill %} body so a slot that exposes `with { ... }`
// bindings can render it with those bindings in scope. The fill sees the
// caller's scope (not the included template's), so references like
// {{ outerUser.name }} resolve correctly from the embed site.
class SlotFill_ {
  construct new(body, scope, comps, slots, registry) {
    _body = body
    _scope = scope
    _comps = comps
    _slots = slots
    _registry = registry
  }

  renderWith(bindings) {
    var child = Scope_.child(_scope)
    for (k in bindings.keys) child.set(k, bindings[k])
    return Render_.renderFull(_body, child, _comps, _slots, {}, _registry)
  }
}

class Render_ {
  construct new(nodes, components, slots, fragmentName, blocks, registry, frags) {
    _nodes = nodes
    _comps = components
    _slots = slots
    _blocks = blocks            // map of block-name → override body AST
    _registry = registry        // TemplateRegistry or null
    _frags = frags              // map of fragment-name → ["fragment", n, p, b]
    _fragment = fragmentName    // if non-null, render only that fragment's body
    _found = false              // set true when target fragment is rendered
    _out = []
  }

  static render(nodes, scope, comps, slots) {
    var r = Render_.new(nodes, comps, slots, null, {}, null, {})
    r.walkAll(nodes, scope)
    return r.output
  }

  static renderFull(nodes, scope, comps, slots, blocks, registry) {
    var r = Render_.new(nodes, comps, slots, null, blocks, registry, {})
    r.walkAll(nodes, scope)
    return r.output
  }

  static renderFullWithFrags(nodes, scope, comps, slots, blocks, registry, frags) {
    var r = Render_.new(nodes, comps, slots, null, blocks, registry, frags)
    r.walkAll(nodes, scope)
    return r.output
  }

  static renderFragment(nodes, scope, name, comps, slots) {
    var r = Render_.new(nodes, comps, slots, name, {}, null, {})
    r.walkAll(nodes, scope)
    if (!r.found_) Fiber.abort("fragment not found: '" + name + "'")
    return r.output
  }

  static renderFragmentFull(nodes, scope, name, comps, slots, blocks, registry) {
    var r = Render_.new(nodes, comps, slots, name, blocks, registry, {})
    r.walkAll(nodes, scope)
    if (!r.found_) Fiber.abort("fragment not found: '" + name + "'")
    return r.output
  }

  output { _out.join("") }
  found_ { _found }

  walkAll(nodes, scope) {
    for (n in nodes) walk_(n, scope)
  }

  walk_(n, scope) {
    var kind = n[0]

    // When rendering a named fragment, skip everything until we enter
    // that fragment's body. Within the fragment, _fragment is cleared
    // so nested nodes render normally.
    if (_fragment != null && kind != "fragment" && kind != "if" &&
        kind != "for") {
      // Walk container nodes so nested fragments can be discovered.
    }

    if (kind == "text") {
      if (_fragment == null) _out.add(n[1])
      return
    }
    if (kind == "interp") {
      if (_fragment == null) {
        var v = evalExpr_(n[1], scope)
        if (n[2]) {
          _out.add(stringify_(v))
        } else {
          _out.add(htmlEscape_(stringify_(v)))
        }
      }
      return
    }
    if (kind == "if") {
      // In fragment-search mode, walk every branch so fragments
      // defined inside conditionals are still reachable.
      if (_fragment != null) {
        for (b in n[1]) walkAll(b[1], scope)
        if (n[2] != null) walkAll(n[2], scope)
        return
      }
      for (b in n[1]) {
        if (truthy_(evalExpr_(b[0], scope))) {
          walkAll(b[1], scope)
          return
        }
      }
      if (n[2] != null) walkAll(n[2], scope)
      return
    }
    if (kind == "for") {
      // In fragment-search mode, walk the body once (without
      // iterating the collection) so nested fragments are found.
      if (_fragment != null) {
        walkAll(n[3], scope)
        return
      }
      var seq = evalExpr_(n[2], scope)
      if (seq == null) return
      var child = Scope_.child(scope)
      var items = toList_(seq)
      var i = 0
      var count = items.count
      while (i < count) {
        child.set(n[1], items[i])
        child.set("loop", {
          "index": i,
          "index1": i + 1,
          "first": i == 0,
          "last": i == count - 1,
          "length": count
        })
        walkAll(n[3], child)
        i = i + 1
      }
      return
    }
    if (kind == "slot") {
      if (_fragment == null) {
        var name = n[1]
        var withBindings = n[2]
        var defaultBody = n[3]
        // Evaluate bindings once; they're either exposed to the fill
        // (via SlotFill_.render) or made visible to the default body.
        var bindings = {}
        for (b in withBindings) bindings[b[0]] = evalExpr_(b[1], scope)

        if (_slots != null && _slots.containsKey(name)) {
          var fill = _slots[name]
          if (fill is String) {
            _out.add(fill)
          } else if (fill is SlotFill_) {
            _out.add(fill.renderWith(bindings))
          } else if (fill is Fn) {
            _out.add(fill.call(bindings))
          } else {
            _out.add(fill.toString)
          }
        } else {
          // Expose bindings to the default body.
          var child = Scope_.child(scope)
          for (k in bindings.keys) child.set(k, bindings[k])
          walkAll(defaultBody, child)
        }
      }
      return
    }
    if (kind == "fragment") {
      // n: ["fragment", name, params, body]  (params null = bare fragment)
      var params = n[2]
      var body = n[3]
      if (_fragment == null) {
        // Parameterized fragments (even with 0 params) don't render inline;
        // they're pure callables. Bare fragments (params == null) do.
        if (params == null) walkAll(body, scope)
      } else if (_fragment == n[1]) {
        _fragment = null
        _found = true
        walkAll(body, scope)
        _fragment = n[1]
      } else {
        walkAll(body, scope)
      }
      return
    }
    if (kind == "set") {
      // Always evaluate. Fragment renders need to see state built
      // up by {% set %}s that appear before the fragment block.
      scope.set(n[1], evalExpr_(n[2], scope))
      return
    }
    if (kind == "include") {
      if (_fragment == null) {
        // Resolve: in-memory components first, then registry loader.
        var tpl = null
        if (_comps != null && _comps.containsKey(n[1])) {
          tpl = _comps[n[1]]
        } else if (_registry != null) {
          tpl = _registry.get(n[1])
        }
        if (tpl == null) Fiber.abort("unknown component: '" + n[1] + "'")
        // Include renders the child AST in the caller's scope so bindings
        // flow through naturally. Child's own {% extends %} is respected
        // via its blocks metadata. Forward tpl's own fragments so any
        // `{% call %}` inside the included template resolves correctly.
        if (tpl.extendsParent_ != null) {
          if (_registry == null) {
            Fiber.abort("included template uses {% extends %} but no registry is set")
          }
          var parent = _registry.get(tpl.extendsParent_)
          _out.add(Render_.renderFullWithFrags(
            parent.ast_, scope, _comps, _slots, tpl.blocks_, _registry, tpl.fragments_))
        } else {
          _out.add(Render_.renderFullWithFrags(
            tpl.ast_, scope, _comps, _slots, tpl.blocks_, _registry, tpl.fragments_))
        }
      }
      return
    }
    if (kind == "block") {
      // Blocks render either their override (from _blocks) or their default.
      var body = _blocks.containsKey(n[1]) ? _blocks[n[1]] : n[2]
      walkAll(body, scope)
      return
    }
    if (kind == "extends") {
      // Extends is consumed at Template.analyze time. A stray node here
      // means someone built an AST manually; ignore rather than abort.
      return
    }
    if (kind == "embed") {
      if (_fragment == null) {
        var name = n[1]
        var withArgs = n[2]
        var fillNodes = n[3]

        var tpl = null
        if (_comps != null && _comps.containsKey(name)) {
          tpl = _comps[name]
        } else if (_registry != null) {
          tpl = _registry.get(name)
        }
        if (tpl == null) Fiber.abort("unknown template: '" + name + "'")

        // Build a slots map: inherit outer slots, then add our fills.
        var slots = {}
        if (_slots != null) {
          for (k in _slots.keys) slots[k] = _slots[k]
        }
        for (f in fillNodes) {
          slots[f[1]] = SlotFill_.new(f[2], scope, _comps, _slots, _registry)
        }

        // Build child ctx from withArgs; slots + components passed along.
        var childCtx = {}
        for (arg in withArgs) childCtx[arg[0]] = evalExpr_(arg[1], scope)
        childCtx["#slots"] = slots
        childCtx["#components"] = _comps
        _out.add(tpl.render(childCtx))
      }
      return
    }
    if (kind == "fill") {
      // Bare {% fill %} at top level is meaningless; fills only matter
      // inside {% embed %}. Ignore silently.
      return
    }
    if (kind == "call") {
      if (_fragment == null) {
        var name = n[1]
        var argExprs = n[2]
        var callBody = n[3]

        if (_frags == null || !_frags.containsKey(name)) {
          Fiber.abort("unknown fragment: '" + name + "'")
        }
        var frag = _frags[name]
        var params = frag[2]
        var body = frag[3]
        // A null params list means the fragment was declared without a
        // parameter clause; {% call %} against it must pass zero args.
        var expected = params == null ? 0 : params.count
        if (argExprs.count != expected) {
          Fiber.abort("call " + name + ": expected " + expected.toString +
            " args, got " + argExprs.count.toString)
        }

        // Evaluate args in caller's scope, bind to fragment's params.
        var child = Scope_.child(scope)
        bindCallArgs_(params, argExprs, child, scope)

        // Expose the call body as a `caller` slot. The fragment can
        // render it via `{% slot caller %}...{% endslot %}`. Using a
        // SlotFill_ lets `caller()` be evaluated lazily, against the
        // calling scope, matching Jinja's semantics.
        var slots = {}
        if (_slots != null) {
          for (k in _slots.keys) slots[k] = _slots[k]
        }
        slots["caller"] = SlotFill_.new(callBody, scope, _comps, _slots, _registry)

        _out.add(Render_.renderFullWithFrags(
          body, child, _comps, slots, _blocks, _registry, _frags))
      }
      return
    }
  }

  bindCallArgs_(params, argExprs, child, scope) {
    if (params == null) return
    var i = 0
    while (i < params.count) {
      child.set(params[i], evalExpr_(argExprs[i], scope))
      i = i + 1
    }
  }

  evalExpr_(e, scope) {
    var k = e[0]
    if (k == "lit") return e[1]
    if (k == "path") return evalPath_(e, scope)
    if (k == "cmp") {
      var l = evalExpr_(e[2], scope)
      var r = evalExpr_(e[3], scope)
      return cmp_(e[1], l, r)
    }
    if (k == "and") {
      var l = evalExpr_(e[1], scope)
      if (!truthy_(l)) return l
      return evalExpr_(e[2], scope)
    }
    if (k == "or") {
      var l = evalExpr_(e[1], scope)
      if (truthy_(l)) return l
      return evalExpr_(e[2], scope)
    }
    if (k == "not") return !truthy_(evalExpr_(e[1], scope))
    if (k == "filter") {
      var v = evalExpr_(e[1], scope)
      var args = []
      for (a in e[3]) args.add(evalExpr_(a, scope))
      return applyFilter_(e[2], v, args)
    }
    Fiber.abort("bad expr node: " + k)
  }

  evalPath_(e, scope) {
    var base = e[1]
    var v = scope.lookup(base)
    // Reserved fallback: `hx` resolves to ctx["#hx"] if the user hasn't
    // bound an `hx` var themselves. Lets templates do `{% if hx.request %}`
    // with the render({ "#hx": ... }) convention.
    if (v == null && base == "hx" && !scope.has("hx")) {
      v = scope.lookup("#hx")
      if (v == null) v = {}
    }
    for (s in e[2]) {
      if (v == null) return null
      if (s[0] == "dot") {
        v = dotGet_(v, s[1])
      } else {
        var idx = evalExpr_(s[1], scope)
        v = indexGet_(v, idx)
      }
    }
    return v
  }

  dotGet_(v, name) {
    if (v is Map) {
      if (v.containsKey(name)) return v[name]
      return null
    }
    if (v is List) {
      if (name == "count") return v.count
      if (name == "first") return v.count > 0 ? v[0] : null
      if (name == "last") return v.count > 0 ? v[-1] : null
      return null
    }
    if (v is String) {
      if (name == "count") return v.count
      return null
    }
    return null
  }

  indexGet_(v, idx) {
    if (v is List) {
      if (!(idx is Num)) return null
      var i = idx.floor
      if (i < 0 || i >= v.count) return null
      return v[i]
    }
    if (v is Map) {
      if (v.containsKey(idx)) return v[idx]
      return null
    }
    if (v is String) {
      if (!(idx is Num)) return null
      var i = idx.floor
      if (i < 0 || i >= v.count) return null
      return v[i]
    }
    return null
  }

  cmp_(op, l, r) {
    if (op == "==") return l == r
    if (op == "!=") return l != r
    // <, <=, >, >= on comparable operands.
    if (l is Num && r is Num) {
      if (op == "<")  return l <  r
      if (op == "<=") return l <= r
      if (op == ">")  return l >  r
      if (op == ">=") return l >= r
    }
    if (l is String && r is String) {
      if (op == "<")  return l <  r
      if (op == "<=") return l <= r
      if (op == ">")  return l >  r
      if (op == ">=") return l >= r
    }
    return false
  }

  applyFilter_(name, v, args) {
    if (name == "escape") return htmlEscape_(stringify_(v))
    if (name == "raw") return stringify_(v)
    if (name == "upper") return stringify_(v).trim().count == 0 ? "" : toUpper_(stringify_(v))
    if (name == "lower") return toLower_(stringify_(v))
    if (name == "length") {
      if (v is List || v is String || v is Map) return v.count
      return 0
    }
    if (name == "default") {
      if (v == null || v == "" || v == false) return args.count > 0 ? args[0] : ""
      return v
    }
    if (name == "join") {
      var sep = args.count > 0 ? stringify_(args[0]) : ""
      if (!(v is List)) return stringify_(v)
      var parts = []
      for (e in v) parts.add(stringify_(e))
      return parts.join(sep)
    }
    Fiber.abort("unknown filter: '" + name + "'")
  }

  truthy_(v) {
    if (v == null) return false
    if (v == false) return false
    if (v == 0) return false
    if (v == "") return false
    if (v is List && v.count == 0) return false
    if (v is Map && v.count == 0) return false
    return true
  }

  toList_(seq) {
    if (seq is List) return seq
    if (seq is Map) {
      var out = []
      for (k in seq.keys) out.add([k, seq[k]])
      return out
    }
    if (seq is String) {
      var out = []
      var i = 0
      while (i < seq.count) {
        out.add(seq[i])
        i = i + 1
      }
      return out
    }
    // Ranges / Sequences: iterate.
    var out = []
    for (e in seq) out.add(e)
    return out
  }

  stringify_(v) {
    if (v == null) return ""
    if (v is String) return v
    return v.toString
  }

  htmlEscape_(s) {
    if (!(s is String)) s = s.toString
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

  toUpper_(s) {
    var out = ""
    var i = 0
    while (i < s.count) {
      var c = s[i]
      var b = c.bytes[0]
      if (b >= 97 && b <= 122) {
        out = out + String.fromByte(b - 32)
      } else {
        out = out + c
      }
      i = i + 1
    }
    return out
  }

  toLower_(s) {
    var out = ""
    var i = 0
    while (i < s.count) {
      var c = s[i]
      var b = c.bytes[0]
      if (b >= 65 && b <= 90) {
        out = out + String.fromByte(b + 32)
      } else {
        out = out + c
      }
      i = i + 1
    }
    return out
  }
}

// --- Public API ------------------------------------------------------------

/// Loader protocol. Any class with `load(name) → String|null` works.
/// The package ships two concrete loaders: MapLoader (in-memory) and
/// FnLoader (adapt any 1-arg function). For a filesystem-backed loader
/// the user would wire up a FnLoader with `@hatch:fs.read(path)`.

class MapLoader {
  construct new(sources) { _sources = sources }
  load(name) {
    if (_sources.containsKey(name)) return _sources[name]
    return null
  }
}

class FnLoader {
  construct new(fn) { _fn = fn }
  load(name) { _fn.call(name) }
}

/// Caches parsed templates by name. Pass a registry to `Template.parseWith`
/// (or call `registry.get(name)`) so `{% extends %}` / `{% include %}` can
/// resolve across files.
class TemplateRegistry {
  construct new(loader) {
    _loader = loader
    _cache = {}
  }

  /// Fetch + parse + cache a template by name. Repeat calls are O(1).
  get(name) {
    if (_cache.containsKey(name)) return _cache[name]
    var src = _loader.load(name)
    if (src == null) Fiber.abort("template not found: '" + name + "'")
    var tpl = Template.parseWith(src, this)
    _cache[name] = tpl
    return tpl
  }

  /// Convenience: render a named template. Equivalent to `get(name).render(ctx)`.
  render(name, ctx) { get(name).render(ctx) }
  renderFragment(name, fragName, ctx) {
    get(name).renderFragment(fragName, ctx)
  }
}

class Template {
  construct parse_(ast, registry) {
    _registry = registry
    analyze_(ast)
  }

  static parse(src) {
    var toks = Lex_.scan(src)
    var ast = Parse_.parse(toks)
    return Template.parse_(ast, null)
  }

  /// Parse + bind to a registry so `{% extends %}` / cross-file `{% include %}`
  /// can resolve. Callers normally reach this through `TemplateRegistry.get`.
  static parseWith(src, registry) {
    var toks = Lex_.scan(src)
    var ast = Parse_.parse(toks)
    return Template.parse_(ast, registry)
  }

  // Split an AST into its extends/block metadata + remaining nodes.
  // Child templates that extend a base are mostly block overrides.
  // Anything outside a `{% block %}` in an extending template is
  // ignored at render time (matches Jinja semantics).
  analyze_(ast) {
    _extends = null
    _blocks = {}
    _frags = {}
    var filtered = []
    for (n in ast) {
      if (n[0] == "extends") {
        _extends = n[1]
      } else if (n[0] == "block") {
        _blocks[n[1]] = n[2]
        filtered.add(n)
      } else {
        if (n[0] == "fragment") _frags[n[1]] = n
        filtered.add(n)
      }
    }
    _ast = filtered
    // Also surface fragments nested one level inside if/for/block so
    // `{% call %}` can reach them. Deeper nesting is an anti-pattern;
    // lift the fragment to the top to call it.
    collectFragments_(_ast)
  }

  collectFragments_(nodes) {
    for (n in nodes) {
      if (n[0] == "fragment") {
        _frags[n[1]] = n
        collectFragments_(n[3])
      } else if (n[0] == "if") {
        for (b in n[1]) collectFragments_(b[1])
        if (n[2] != null) collectFragments_(n[2])
      } else if (n[0] == "for") {
        collectFragments_(n[3])
      } else if (n[0] == "block") {
        collectFragments_(n[2])
      } else if (n[0] == "slot") {
        collectFragments_(n[3])
      }
    }
  }

  ast_ { _ast }
  blocks_ { _blocks }
  extendsParent_ { _extends }
  registry_ { _registry }
  fragments_ { _frags }

  /// Render with optional context map.
  ///
  /// ```wren
  /// tpl.render({ "user": u })                    // plain render
  /// tpl.render({ "user": u, "#slots": slots })   // named slot bodies
  /// tpl.render({ "user": u, "#hx": hx })         // expose as `hx` path
  /// ```
  render(ctx) {
    ctx = ctx == null ? {} : ctx
    // Wrap ctx in a child scope so {% set %} doesn't mutate the caller's map.
    var scope = Scope_.child(Scope_.root(ctx))
    if (_extends != null) {
      if (_registry == null) {
        Fiber.abort("template uses {% extends %} but was parsed without a registry")
      }
      var parent = _registry.get(_extends)
      return parent.renderWithOverrides_(scope, ctx, _blocks)
    }
    var slots = ctx.containsKey("#slots") ? ctx["#slots"] : null
    var comps = ctx.containsKey("#components") ? ctx["#components"] : {}
    return Render_.renderFullWithFrags(_ast, scope, comps, slots, {}, _registry, _frags)
  }

  /// Render only the named `{% fragment %}` block. The rest of
  /// the template is walked but only emits output once we're
  /// inside the target fragment.
  ///
  /// ```wren
  /// tpl.renderFragment("user-row", { "user": u })
  /// ```
  ///
  /// If the fragment has params, its ctx keys populate them.
  renderFragment(name, ctx) {
    ctx = ctx == null ? {} : ctx
    var scope = Scope_.child(Scope_.root(ctx))
    var slots = ctx.containsKey("#slots") ? ctx["#slots"] : null
    var comps = ctx.containsKey("#components") ? ctx["#components"] : {}
    return Render_.renderFragmentFull(_ast, scope, name, comps, slots, _blocks, _registry)
  }

  // Internal: render this template as the target of an `extends` chain.
  // Child's block overrides are merged on top of our own blocks, then the
  // chain walks up until a non-extending template is reached.
  renderWithOverrides_(scope, ctx, overrides) {
    if (_extends != null) {
      var parent = _registry.get(_extends)
      var merged = {}
      for (k in _blocks.keys) merged[k] = _blocks[k]       // our blocks
      for (k in overrides.keys) merged[k] = overrides[k]   // child's win
      return parent.renderWithOverrides_(scope, ctx, merged)
    }
    var slots = ctx.containsKey("#slots") ? ctx["#slots"] : null
    var comps = ctx.containsKey("#components") ? ctx["#components"] : {}
    return Render_.renderFullWithFrags(_ast, scope, comps, slots, overrides, _registry, _frags)
  }
}

// --- htmx response helper --------------------------------------------------
/// Thin bag of body + headers. No HTTP opinions; the caller
/// picks a transport. Every chainable method returns `this`, so
/// a response can be built inline:
///
/// ```wren
/// var r = Hx.response(tpl.renderFragment("row", ctx))
///   .trigger("user-updated", { "id": 42 })
///   .pushUrl("/users/42")
///   .reswap("outerHTML")
/// // r.body → string, r.headers → map of header → value
/// ```
class HxResponse {
  construct new(body) {
    _body = body
    _headers = {}
  }

  body { _body }
  headers { _headers }

  /// Fire one or more htmx client-side events after the swap.
  /// Passing a Map encodes as JSON-style so the client receives a
  /// detail payload.
  trigger(name) { setHeader_("HX-Trigger", jsonEvent_(name, null)) }
  trigger(name, detail) { setHeader_("HX-Trigger", jsonEvent_(name, detail)) }

  triggerAfterSettle(name) { setHeader_("HX-Trigger-After-Settle", jsonEvent_(name, null)) }
  triggerAfterSettle(name, detail) { setHeader_("HX-Trigger-After-Settle", jsonEvent_(name, detail)) }

  triggerAfterSwap(name) { setHeader_("HX-Trigger-After-Swap", jsonEvent_(name, null)) }
  triggerAfterSwap(name, detail) { setHeader_("HX-Trigger-After-Swap", jsonEvent_(name, detail)) }

  /// Client-side navigation.
  pushUrl(url) { setHeader_("HX-Push-Url", url) }
  replaceUrl(url) { setHeader_("HX-Replace-Url", url) }
  redirect(url) { setHeader_("HX-Redirect", url) }
  location(url) { setHeader_("HX-Location", url) }
  refresh() { setHeader_("HX-Refresh", "true") }

  /// Swap targeting.
  retarget(sel) { setHeader_("HX-Retarget", sel) }
  reswap(mode) { setHeader_("HX-Reswap", mode) }
  reselect(sel) { setHeader_("HX-Reselect", sel) }

  /// Raw escape hatch.
  header(name, value) { setHeader_(name, value) }

  setHeader_(name, value) {
    _headers[name] = value
    return this
  }

  // Encode an event name (+ optional detail) in the format htmx expects.
  // Single event, no detail → bare "name". With detail → JSON object.
  jsonEvent_(name, detail) {
    if (detail == null) {
      // Append to existing header if already set (comma-separated).
      if (_headers.containsKey("HX-Trigger")) {
        var prev = _headers["HX-Trigger"]
        if (!prev.startsWith("{")) return prev + ", " + name
      }
      return name
    }
    return "{\"" + name + "\": " + jsonValue_(detail) + "}"
  }

  jsonValue_(v) {
    if (v == null) return "null"
    if (v == true) return "true"
    if (v == false) return "false"
    if (v is Num) return v.toString
    if (v is String) return "\"" + jsonEscape_(v) + "\""
    if (v is List) {
      var parts = []
      for (e in v) parts.add(jsonValue_(e))
      return "[" + parts.join(",") + "]"
    }
    if (v is Map) {
      var parts = []
      for (k in v.keys) {
        parts.add("\"" + jsonEscape_(k.toString) + "\":" + jsonValue_(v[k]))
      }
      return "{" + parts.join(",") + "}"
    }
    return "\"" + jsonEscape_(v.toString) + "\""
  }

  jsonEscape_(s) {
    var out = ""
    var i = 0
    while (i < s.count) {
      var c = s[i]
      if (c == "\\") { out = out + "\\\\" }
      else if (c == "\"") { out = out + "\\\"" }
      else if (c == "\n") { out = out + "\\n" }
      else if (c == "\r") { out = out + "\\r" }
      else if (c == "\t") { out = out + "\\t" }
      else { out = out + c }
      i = i + 1
    }
    return out
  }
}

class Hx {
  static response(body) { HxResponse.new(body) }
  static response() { HxResponse.new("") }

  /// Detects htmx from a request headers map. Accepts any of the
  /// common framework shapes.
  ///
  /// ```wren
  /// Hx.isRequest(req.headers)    //= true if HX-Request present / truthy
  /// ```
  static isRequest(headers) {
    if (headers == null) return false
    for (k in headers.keys) {
      var lk = k is String ? lowerAscii_(k) : k
      if (lk == "hx-request") {
        var v = headers[k]
        return v == true || v == "true"
      }
    }
    return false
  }

  static context(headers) {
    var ctx = {
      "request": false,
      "boosted": false,
      "target": null,
      "trigger": null,
      "triggerName": null,
      "currentUrl": null
    }
    if (headers == null) return ctx
    for (k in headers.keys) {
      var lk = k is String ? lowerAscii_(k) : k
      var v = headers[k]
      if (lk == "hx-request") ctx["request"] = (v == true || v == "true")
      if (lk == "hx-boosted") ctx["boosted"] = (v == true || v == "true")
      if (lk == "hx-target") ctx["target"] = v
      if (lk == "hx-trigger") ctx["trigger"] = v
      if (lk == "hx-trigger-name") ctx["triggerName"] = v
      if (lk == "hx-current-url") ctx["currentUrl"] = v
    }
    return ctx
  }

  static lowerAscii_(s) {
    var out = ""
    var i = 0
    while (i < s.count) {
      var c = s[i]
      var b = c.bytes[0]
      if (b >= 65 && b <= 90) {
        out = out + String.fromByte(b + 32)
      } else {
        out = out + c
      }
      i = i + 1
    }
    return out
  }
}
