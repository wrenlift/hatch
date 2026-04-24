import "./template" for
  Template, TemplateRegistry, MapLoader, FnLoader, Hx, HxResponse, TemplateError
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

// --- Basic rendering -------------------------------------------------------

Test.describe("Template: literal text") {
  Test.it("passes text through verbatim") {
    var t = Template.parse("<h1>Hello world</h1>")
    Expect.that(t.render(null)).toBe("<h1>Hello world</h1>")
  }
  Test.it("handles an empty template") {
    Expect.that(Template.parse("").render({})).toBe("")
  }
  Test.it("handles lone braces that don't open directives") {
    var t = Template.parse("a { b } c")
    Expect.that(t.render(null)).toBe("a { b } c")
  }
}

// --- Interpolation ---------------------------------------------------------

Test.describe("Template: {{ expr }} interpolation") {
  Test.it("renders a bare variable") {
    var t = Template.parse("Hello {{ name }}!")
    Expect.that(t.render({ "name": "world" })).toBe("Hello world!")
  }
  Test.it("HTML-escapes by default") {
    var t = Template.parse("<p>{{ msg }}</p>")
    Expect.that(t.render({ "msg": "<b>&hi</b>" }))
      .toBe("<p>&lt;b&gt;&amp;hi&lt;/b&gt;</p>")
  }
  Test.it("raw interpolation {{{ }}} skips escaping") {
    var t = Template.parse("<p>{{{ html }}}</p>")
    Expect.that(t.render({ "html": "<b>hi</b>" })).toBe("<p><b>hi</b></p>")
  }
  Test.it("renders nested paths via dots") {
    var t = Template.parse("{{ user.name }}")
    Expect.that(t.render({ "user": { "name": "Ada" } })).toBe("Ada")
  }
  Test.it("renders list subscript") {
    var t = Template.parse("{{ items[0] }} / {{ items[2] }}")
    Expect.that(t.render({ "items": ["a", "b", "c"] })).toBe("a / c")
  }
  Test.it("renders string literal index") {
    var t = Template.parse("{{ m[\"k\"] }}")
    Expect.that(t.render({ "m": { "k": 42 } })).toBe("42")
  }
  Test.it("null variables render as empty string") {
    var t = Template.parse("a{{ missing }}b")
    Expect.that(t.render({})).toBe("ab")
  }
  Test.it("Num renders via toString") {
    var t = Template.parse("{{ n }}")
    Expect.that(t.render({ "n": 3.5 })).toBe("3.5")
  }
}

// --- Literals + comparisons ------------------------------------------------

Test.describe("Template: expression literals") {
  Test.it("string literal") {
    var t = Template.parse("{{ \"hi\" }}")
    Expect.that(t.render({})).toBe("hi")
  }
  Test.it("numeric literal") {
    var t = Template.parse("{{ 42 }}")
    Expect.that(t.render({})).toBe("42")
  }
  Test.it("boolean literals") {
    Expect.that(Template.parse("{{ true }}").render({})).toBe("true")
    Expect.that(Template.parse("{{ false }}").render({})).toBe("false")
  }
  Test.it("null literal renders empty") {
    Expect.that(Template.parse("{{ null }}").render({})).toBe("")
  }
}

Test.describe("Template: comparisons") {
  Test.it("== / != on nums") {
    Expect.that(Template.parse("{% if x == 1 %}y{% endif %}").render({ "x": 1 })).toBe("y")
    Expect.that(Template.parse("{% if x != 1 %}y{% endif %}").render({ "x": 2 })).toBe("y")
  }
  Test.it("< <= > >= on nums") {
    var t = Template.parse("{% if n > 2 %}big{% endif %}")
    Expect.that(t.render({ "n": 3 })).toBe("big")
    Expect.that(t.render({ "n": 1 })).toBe("")
  }
  Test.it("comparisons on strings") {
    var t = Template.parse("{% if s == \"ok\" %}yes{% endif %}")
    Expect.that(t.render({ "s": "ok" })).toBe("yes")
  }
}

// --- Boolean operators -----------------------------------------------------

Test.describe("Template: and / or / not") {
  Test.it("and short-circuits on falsy left") {
    var t = Template.parse("{% if a and b %}yes{% endif %}")
    Expect.that(t.render({ "a": true, "b": true })).toBe("yes")
    Expect.that(t.render({ "a": false, "b": true })).toBe("")
  }
  Test.it("or short-circuits on truthy left") {
    var t = Template.parse("{% if a or b %}yes{% endif %}")
    Expect.that(t.render({ "a": false, "b": true })).toBe("yes")
    Expect.that(t.render({ "a": false, "b": false })).toBe("")
  }
  Test.it("not negates truthiness") {
    var t = Template.parse("{% if not empty %}yes{% endif %}")
    Expect.that(t.render({ "empty": false })).toBe("yes")
    Expect.that(t.render({ "empty": true })).toBe("")
  }
}

// --- if / elif / else ------------------------------------------------------

Test.describe("Template: {% if %}") {
  Test.it("if / endif") {
    var t = Template.parse("{% if v %}yes{% endif %}")
    Expect.that(t.render({ "v": true })).toBe("yes")
    Expect.that(t.render({ "v": false })).toBe("")
  }
  Test.it("if / else / endif") {
    var t = Template.parse("{% if v %}A{% else %}B{% endif %}")
    Expect.that(t.render({ "v": true })).toBe("A")
    Expect.that(t.render({ "v": false })).toBe("B")
  }
  Test.it("if / elif / else / endif picks first truthy") {
    var t = Template.parse(
      "{% if a %}A{% elif b %}B{% elif c %}C{% else %}D{% endif %}")
    Expect.that(t.render({ "a": true,  "b": false, "c": false })).toBe("A")
    Expect.that(t.render({ "a": false, "b": true,  "c": false })).toBe("B")
    Expect.that(t.render({ "a": false, "b": false, "c": true  })).toBe("C")
    Expect.that(t.render({ "a": false, "b": false, "c": false })).toBe("D")
  }
  Test.it("null / 0 / \"\" / empty list are falsy") {
    var t = Template.parse("{% if v %}truthy{% else %}falsy{% endif %}")
    Expect.that(t.render({ "v": null })).toBe("falsy")
    Expect.that(t.render({ "v": 0 })).toBe("falsy")
    Expect.that(t.render({ "v": "" })).toBe("falsy")
    Expect.that(t.render({ "v": [] })).toBe("falsy")
    Expect.that(t.render({ "v": {} })).toBe("falsy")
    Expect.that(t.render({ "v": "x" })).toBe("truthy")
    Expect.that(t.render({ "v": 1 })).toBe("truthy")
    Expect.that(t.render({ "v": [1] })).toBe("truthy")
  }
}

// --- for loops -------------------------------------------------------------

Test.describe("Template: {% for %}") {
  Test.it("iterates a list") {
    var t = Template.parse("{% for x in xs %}[{{ x }}]{% endfor %}")
    Expect.that(t.render({ "xs": ["a", "b", "c"] })).toBe("[a][b][c]")
  }
  Test.it("iterates a range passed via ctx") {
    var t = Template.parse("{% for i in r %}{{ i }}{% endfor %}")
    Expect.that(t.render({ "r": 1..3 })).toBe("123")
  }
  Test.it("iterates a map as [key, value] pairs") {
    var t = Template.parse("{% for p in m %}{{ p[0] }}={{ p[1] }};{% endfor %}")
    var out = t.render({ "m": { "a": 1, "b": 2 } })
    // Wren Map iteration order isn't stable — check both pairs appear.
    Expect.that(out).toContain("a=1;")
    Expect.that(out).toContain("b=2;")
  }
  Test.it("loop.index / index1 / first / last / length") {
    var t = Template.parse(
      "{% for x in xs %}{{ loop.index }}:{{ x }}{% if loop.last %}${% endif %};{% endfor %}")
    Expect.that(t.render({ "xs": ["a", "b", "c"] })).toBe("0:a;1:b;2:c$;")
  }
  Test.it("empty sequence emits nothing") {
    var t = Template.parse("{% for x in xs %}[{{ x }}]{% endfor %}")
    Expect.that(t.render({ "xs": [] })).toBe("")
  }
  Test.it("loop binding doesn't leak into outer scope") {
    var t = Template.parse("{% for x in xs %}{{ x }}{% endfor %}{{ x }}")
    Expect.that(t.render({ "xs": [1, 2] })).toBe("12")
  }
}

// --- set -------------------------------------------------------------------

Test.describe("Template: {% set %}") {
  Test.it("binds a simple literal") {
    var t = Template.parse("{% set x = 42 %}{{ x }}")
    Expect.that(t.render({})).toBe("42")
  }
  Test.it("binds the rhs expression (paths, literals, comparisons)") {
    Expect.that(Template.parse("{% set n = a %}{{ n }}").render({ "a": 7 })).toBe("7")
    Expect.that(Template.parse("{% set ok = a > 5 %}{{ ok }}").render({ "a": 7 })).toBe("true")
    Expect.that(Template.parse("{% set greet = \"hi\" %}{{ greet }}").render({})).toBe("hi")
  }
  Test.it("doesn't mutate the caller's context") {
    var ctx = { "x": 1 }
    var t = Template.parse("{% set x = 99 %}{{ x }}")
    Expect.that(t.render(ctx)).toBe("99")
    Expect.that(ctx["x"]).toBe(1)
  }
}

// --- Slots -----------------------------------------------------------------

Test.describe("Template: {% slot %}") {
  Test.it("renders default body when no slot provided") {
    var t = Template.parse("[{% slot body %}default{% endslot %}]")
    Expect.that(t.render({})).toBe("[default]")
  }
  Test.it("slot bodies passed via #slots override the default") {
    var t = Template.parse("[{% slot body %}default{% endslot %}]")
    Expect.that(t.render({ "#slots": { "body": "provided" } }))
      .toBe("[provided]")
  }
  Test.it("multiple slots resolve independently") {
    var t = Template.parse(
      "{% slot a %}A{% endslot %}/{% slot b %}B{% endslot %}")
    Expect.that(t.render({ "#slots": { "a": "X" } })).toBe("X/B")
  }
}

// --- Fragments -------------------------------------------------------------

Test.describe("Template: {% fragment %}") {
  Test.it("fragment body renders inline during full render") {
    var t = Template.parse(
      "page<br>{% fragment row %}R{{ x }}{% endfragment %}<br>end")
    Expect.that(t.render({ "x": 1 })).toBe("page<br>R1<br>end")
  }
  Test.it("renderFragment emits only the target body") {
    var t = Template.parse(
      "page<br>{% fragment row %}R{{ x }}{% endfragment %}<br>end")
    Expect.that(t.renderFragment("row", { "x": 7 })).toBe("R7")
  }
  Test.it("renderFragment sees {% set %} state from before the fragment") {
    var t = Template.parse(
      "{% set prefix = \"u-\" %}{% fragment row %}{{ prefix }}{{ id }}{% endfragment %}")
    Expect.that(t.renderFragment("row", { "id": 42 })).toBe("u-42")
  }
  Test.it("renderFragment errors when name is unknown") {
    var t = Template.parse("{% fragment foo %}x{% endfragment %}")
    var err = Fiber.new {
      t.renderFragment("missing", {})
    }.try()
    Expect.that(err).toContain("fragment not found")
  }
}

// --- Filters ---------------------------------------------------------------

Test.describe("Template: filters") {
  Test.it("| upper") {
    Expect.that(Template.parse("{{ s | upper }}").render({ "s": "abc" })).toBe("ABC")
  }
  Test.it("| lower") {
    Expect.that(Template.parse("{{ s | lower }}").render({ "s": "ABC" })).toBe("abc")
  }
  Test.it("| length on strings / lists / maps") {
    Expect.that(Template.parse("{{ s | length }}").render({ "s": "hello" })).toBe("5")
    Expect.that(Template.parse("{{ xs | length }}").render({ "xs": [1,2,3] })).toBe("3")
    Expect.that(Template.parse("{{ m | length }}").render({ "m": { "a": 1, "b": 2 } })).toBe("2")
  }
  Test.it("| default(fallback) fills null / empty / false") {
    var t = Template.parse("{{ v | default(\"-\") }}")
    Expect.that(t.render({ "v": null })).toBe("-")
    Expect.that(t.render({ "v": "" })).toBe("-")
    Expect.that(t.render({ "v": "x" })).toBe("x")
  }
  Test.it("| join(sep)") {
    var t = Template.parse("{{ xs | join(\", \") }}")
    Expect.that(t.render({ "xs": [1, 2, 3] })).toBe("1, 2, 3")
  }
  Test.it("| escape + {{{ }}} combo escapes once; {{{ }}} alone stays raw") {
    // {{{ }}} suppresses the default auto-escape, so `| escape` inside
    // gives us control over exactly one escape pass.
    var t = Template.parse("{{{ s | escape }}}")
    Expect.that(t.render({ "s": "<b>" })).toBe("&lt;b&gt;")
    // {{{ }}} alone passes through verbatim.
    var t2 = Template.parse("{{{ s }}}")
    Expect.that(t2.render({ "s": "<b>" })).toBe("<b>")
  }
  Test.it("chained filters left-to-right") {
    var t = Template.parse("{{ s | upper | length }}")
    Expect.that(t.render({ "s": "abc" })).toBe("3")
  }
}

// --- Comments + whitespace trim --------------------------------------------

Test.describe("Template: comments and whitespace") {
  Test.it("{# ... #} is stripped") {
    var t = Template.parse("a{# hi #}b")
    Expect.that(t.render({})).toBe("ab")
  }
  Test.it("{%- trims left whitespace") {
    var t = Template.parse("line1   \n{%- if true %}X{% endif %}")
    Expect.that(t.render({})).toBe("line1X")
  }
  Test.it("-%} trims right whitespace") {
    var t = Template.parse("{% if true -%}\n   X{% endif %}")
    Expect.that(t.render({})).toBe("X")
  }
}

// --- Components (via {% include %}) ----------------------------------------

Test.describe("Template: components via include") {
  Test.it("renders a registered component") {
    var card = Template.parse("<card>{{ name }}</card>")
    var page = Template.parse("[{% include \"card\" %}]")
    var out = page.render({ "name": "Ada", "#components": { "card": card } })
    Expect.that(out).toBe("[<card>Ada</card>]")
  }
  Test.it("errors on unknown component") {
    var page = Template.parse("{% include \"missing\" %}")
    var err = Fiber.new { page.render({}) }.try()
    Expect.that(err).toContain("unknown component")
  }
}

// --- htmx context injection -----------------------------------------------

Test.describe("Template: hx.* path via #hx") {
  Test.it("hx.request resolves from ctx[\"#hx\"]") {
    var t = Template.parse(
      "{% if hx.request %}frag{% else %}full{% endif %}")
    Expect.that(t.render({ "#hx": { "request": true } })).toBe("frag")
    Expect.that(t.render({ "#hx": { "request": false } })).toBe("full")
    Expect.that(t.render({})).toBe("full")
  }
  Test.it("hx.target reads through") {
    var t = Template.parse("{{ hx.target }}")
    Expect.that(t.render({ "#hx": { "target": "#cart" } })).toBe("#cart")
  }
}

// --- Hx response helper ----------------------------------------------------

Test.describe("Hx.response") {
  Test.it("body + empty headers") {
    var r = Hx.response("<p>hi</p>")
    Expect.that(r.body).toBe("<p>hi</p>")
    Expect.that(r.headers.count).toBe(0)
  }
  Test.it("trigger(name) with no detail emits bare name") {
    var r = Hx.response("x").trigger("userSaved")
    Expect.that(r.headers["HX-Trigger"]).toBe("userSaved")
  }
  Test.it("trigger(name, detail) encodes JSON") {
    var r = Hx.response("x").trigger("userSaved", { "id": 42 })
    Expect.that(r.headers["HX-Trigger"]).toBe("{\"userSaved\": {\"id\":42}}")
  }
  Test.it("pushUrl / replaceUrl / redirect / refresh") {
    var r = Hx.response("x")
      .pushUrl("/a")
      .replaceUrl("/b")
      .redirect("/c")
      .refresh()
    Expect.that(r.headers["HX-Push-Url"]).toBe("/a")
    Expect.that(r.headers["HX-Replace-Url"]).toBe("/b")
    Expect.that(r.headers["HX-Redirect"]).toBe("/c")
    Expect.that(r.headers["HX-Refresh"]).toBe("true")
  }
  Test.it("retarget / reswap / reselect") {
    var r = Hx.response("x")
      .retarget("#cart")
      .reswap("outerHTML")
      .reselect(".row")
    Expect.that(r.headers["HX-Retarget"]).toBe("#cart")
    Expect.that(r.headers["HX-Reswap"]).toBe("outerHTML")
    Expect.that(r.headers["HX-Reselect"]).toBe(".row")
  }
  Test.it("triggerAfterSettle + triggerAfterSwap set distinct headers") {
    var r = Hx.response("x")
      .triggerAfterSettle("a")
      .triggerAfterSwap("b")
    Expect.that(r.headers["HX-Trigger-After-Settle"]).toBe("a")
    Expect.that(r.headers["HX-Trigger-After-Swap"]).toBe("b")
  }
  Test.it("header() sets arbitrary headers") {
    var r = Hx.response("x").header("X-My", "v")
    Expect.that(r.headers["X-My"]).toBe("v")
  }
}

Test.describe("Hx.isRequest / Hx.context") {
  Test.it("isRequest true on HX-Request: true") {
    Expect.that(Hx.isRequest({ "HX-Request": "true" })).toBe(true)
    Expect.that(Hx.isRequest({ "hx-request": "true" })).toBe(true)
    Expect.that(Hx.isRequest({ "HX-Request": true })).toBe(true)
  }
  Test.it("isRequest false when missing or falsy") {
    Expect.that(Hx.isRequest(null)).toBe(false)
    Expect.that(Hx.isRequest({})).toBe(false)
    Expect.that(Hx.isRequest({ "HX-Request": "false" })).toBe(false)
  }
  Test.it("context() flattens hx-* headers") {
    var c = Hx.context({
      "HX-Request": "true",
      "HX-Boosted": "true",
      "HX-Target": "#main",
      "HX-Trigger": "btn",
      "HX-Trigger-Name": "save",
      "HX-Current-URL": "/page"
    })
    Expect.that(c["request"]).toBe(true)
    Expect.that(c["boosted"]).toBe(true)
    Expect.that(c["target"]).toBe("#main")
    Expect.that(c["trigger"]).toBe("btn")
    Expect.that(c["triggerName"]).toBe("save")
    Expect.that(c["currentUrl"]).toBe("/page")
  }
}

// --- Loaders + registry ----------------------------------------------------

Test.describe("MapLoader / FnLoader / TemplateRegistry") {
  Test.it("MapLoader returns source by name or null") {
    var l = MapLoader.new({ "a": "<a>", "b": "<b>" })
    Expect.that(l.load("a")).toBe("<a>")
    Expect.that(l.load("b")).toBe("<b>")
    Expect.that(l.load("missing")).toBe(null)
  }
  Test.it("FnLoader adapts any Fn") {
    var l = FnLoader.new(Fn.new {|n| n == "x" ? "X!" : null })
    Expect.that(l.load("x")).toBe("X!")
    Expect.that(l.load("y")).toBe(null)
  }
  Test.it("registry caches parsed templates") {
    var count = 0
    var loader = FnLoader.new(Fn.new {|n|
      count = count + 1
      n == "hi" ? "Hi {{ n }}" : null
    })
    var reg = TemplateRegistry.new(loader)
    Expect.that(reg.render("hi", { "n": "A" })).toBe("Hi A")
    Expect.that(reg.render("hi", { "n": "B" })).toBe("Hi B")
    // Second render should NOT have re-loaded the source.
    Expect.that(count).toBe(1)
  }
  Test.it("missing template aborts") {
    var reg = TemplateRegistry.new(MapLoader.new({}))
    var err = Fiber.new { reg.render("nope", {}) }.try()
    Expect.that(err).toContain("template not found")
  }
}

// --- Template inheritance (extends / block) -------------------------------

Test.describe("Template: {% extends %} + {% block %}") {
  Test.it("child overrides a named block") {
    var reg = TemplateRegistry.new(MapLoader.new({
      "base": "<html>{% block content %}DEFAULT{% endblock %}</html>",
      "page": "{% extends \"base\" %}{% block content %}CHILD{% endblock %}"
    }))
    Expect.that(reg.render("page", {})).toBe("<html>CHILD</html>")
  }
  Test.it("block default is used when child doesn't override") {
    var reg = TemplateRegistry.new(MapLoader.new({
      "base":
        "<head>{% block title %}Default Title{% endblock %}</head>" +
        "<body>{% block body %}DEFAULT{% endblock %}</body>",
      "page":
        "{% extends \"base\" %}{% block body %}OVERRIDE{% endblock %}"
    }))
    Expect.that(reg.render("page", {}))
      .toBe("<head>Default Title</head><body>OVERRIDE</body>")
  }
  Test.it("three-level inheritance: child wins over middle") {
    var reg = TemplateRegistry.new(MapLoader.new({
      "base":   "<[{% block a %}base-a{% endblock %}]>",
      "middle": "{% extends \"base\" %}{% block a %}mid-a{% endblock %}",
      "leaf":   "{% extends \"middle\" %}{% block a %}leaf-a{% endblock %}"
    }))
    Expect.that(reg.render("leaf", {})).toBe("<[leaf-a]>")
  }
  Test.it("non-extending template with {% block %} renders the default") {
    var t = Template.parse("<x>{% block body %}default{% endblock %}</x>")
    Expect.that(t.render({})).toBe("<x>default</x>")
  }
  Test.it("block body sees ctx variables") {
    var reg = TemplateRegistry.new(MapLoader.new({
      "base": "{% block b %}hello {{ name }}{% endblock %}",
      "page": "{% extends \"base\" %}{% block b %}hi {{ name | upper }}{% endblock %}"
    }))
    Expect.that(reg.render("page", { "name": "ada" })).toBe("hi ADA")
  }
  Test.it("using {% extends %} without a registry aborts") {
    var t = Template.parse("{% extends \"x\" %}")
    var err = Fiber.new { t.render({}) }.try()
    Expect.that(err).toContain("without a registry")
  }
}

// --- include via registry --------------------------------------------------

Test.describe("Template: {% include %} resolves through registry") {
  Test.it("cross-file include works with a registry") {
    var reg = TemplateRegistry.new(MapLoader.new({
      "card": "<card>{{ name }}</card>",
      "page": "[{% include \"card\" %}]"
    }))
    Expect.that(reg.render("page", { "name": "Ada" }))
      .toBe("[<card>Ada</card>]")
  }
  Test.it("included template that itself extends resolves the chain") {
    var reg = TemplateRegistry.new(MapLoader.new({
      "base":    "<wrap>{% block inner %}d{% endblock %}</wrap>",
      "derived": "{% extends \"base\" %}{% block inner %}{{ name }}{% endblock %}",
      "page":    "[{% include \"derived\" %}]"
    }))
    Expect.that(reg.render("page", { "name": "A" })).toBe("[<wrap>A</wrap>]")
  }
}

// --- Scoped slots + embed/fill --------------------------------------------

Test.describe("Template: scoped slots (with bindings)") {
  Test.it("default body sees slot's with-bindings") {
    var t = Template.parse(
      "[{% slot foot with { n: items | length } %}{{ n }} items{% endslot %}]")
    Expect.that(t.render({ "items": [1,2,3,4] })).toBe("[4 items]")
  }
  Test.it("embed/fill: fill receives the slot's bindings in scope") {
    var reg = TemplateRegistry.new(MapLoader.new({
      "card":
        "<div>{% slot foot with { n: items | length } %}default{% endslot %}</div>",
      "page":
        "{% embed \"card\" with { items: xs } %}" +
          "{% fill foot %}<b>{{ n }}</b>{% endfill %}" +
        "{% endembed %}"
    }))
    Expect.that(reg.render("page", { "xs": [1, 2, 3] }))
      .toBe("<div><b>3</b></div>")
  }
  Test.it("fill body sees the caller's scope, not the component's") {
    // `title` is only in the page's ctx, not in card's. The fill runs
    // against the caller's scope so it still resolves.
    var reg = TemplateRegistry.new(MapLoader.new({
      "card":
        "<x>{% slot body with { n: 42 } %}default{% endslot %}</x>",
      "page":
        "{% embed \"card\" %}" +
          "{% fill body %}{{ title }}-{{ n }}{% endfill %}" +
        "{% endembed %}"
    }))
    Expect.that(reg.render("page", { "title": "T" })).toBe("<x>T-42</x>")
  }
  Test.it("unfilled slot renders default, with bindings exposed there too") {
    var reg = TemplateRegistry.new(MapLoader.new({
      "card": "[{% slot body with { n: 7 } %}<i>{{ n }}</i>{% endslot %}]",
      "page": "{% embed \"card\" %}{% endembed %}"
    }))
    Expect.that(reg.render("page", {})).toBe("[<i>7</i>]")
  }
  Test.it("string fill via #slots works without a template-level fill") {
    var t = Template.parse(
      "[{% slot body with { n: 3 } %}default{% endslot %}]")
    Expect.that(t.render({ "#slots": { "body": "SET" } })).toBe("[SET]")
  }
  Test.it("Fn fill receives bindings map") {
    var t = Template.parse(
      "[{% slot body with { n: 5 } %}default{% endslot %}]")
    var out = t.render({
      "#slots": { "body": Fn.new {|b| "n=" + b["n"].toString } }
    })
    Expect.that(out).toBe("[n=5]")
  }
  Test.it("embed with-args initialises the child template's ctx") {
    var reg = TemplateRegistry.new(MapLoader.new({
      "card": "<c>{{ label }}</c>",
      "page": "{% embed \"card\" with { label: \"HI\" } %}{% endembed %}"
    }))
    Expect.that(reg.render("page", {})).toBe("<c>HI</c>")
  }
  Test.it("embed body may only contain fills + whitespace") {
    var err = Fiber.new {
      Template.parse("{% embed \"x\" %}stray text{% endembed %}")
    }.try()
    Expect.that(err).toContain("only {% fill %} blocks allowed")
  }
}

// --- Big end-to-end --------------------------------------------------------

Test.describe("Template: realistic htmx flow") {
  Test.it("same template serves full page and fragment response") {
    var src =
      "{% if hx.request %}" +
        "{% fragment row %}<tr id=\"u-{{ id }}\">{{ name }}</tr>{% endfragment %}" +
      "{% else %}" +
        "<html><body><table>" +
          "{% for u in users %}" +
            "<tr id=\"u-{{ u.id }}\">{{ u.name }}</tr>" +
          "{% endfor %}" +
        "</table></body></html>" +
      "{% endif %}"
    var t = Template.parse(src)

    var full = t.render({ "users": [{ "id": 1, "name": "Ada" },
                                    { "id": 2, "name": "Ben" }] })
    Expect.that(full).toContain("<html>")
    Expect.that(full).toContain("<tr id=\"u-1\">Ada</tr>")
    Expect.that(full).toContain("<tr id=\"u-2\">Ben</tr>")

    // Fragment response for htmx partial update.
    var partial = t.renderFragment("row", { "id": 7, "name": "Zoe" })
    Expect.that(partial).toBe("<tr id=\"u-7\">Zoe</tr>")
  }
}

Test.run()
