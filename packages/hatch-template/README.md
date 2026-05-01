Jinja / Twig-style templating for HTML and XML, with first-class htmx support — fragments, components, slots, conditionals, loops, and response-header helpers. `Template.parse(source)` compiles once, `tpl.render(ctx)` produces output, `tpl.renderFragment(name, ctx)` returns just one named block for partial-update responses.

## Overview

The syntax is the conventional double-brace / percent shape. Interpolation is HTML-escaped by default; triple braces opt into raw output for trusted strings.

```wren
import "@hatch:template" for Template, Hx

var tpl = Template.parse("<h1>Hello {{ name }}</h1>")
System.print(tpl.render({ "name": "world" }))
// <h1>Hello world</h1>
```

Statement tags cover the usual control-flow and structural pieces:

| Tag | Effect |
|-----|--------|
| `{{ expr }}` / `{{{ expr }}}` | Escaped / raw interpolation |
| `{% if expr %}` / `{% elif %}` / `{% else %}` / `{% endif %}` | Conditional |
| `{% for x in expr %}` / `{% endfor %}` | Iteration |
| `{% slot name %}` / `{% endslot %}` | Named slot with default body |
| `{% fragment name %}` / `{% endfragment %}` | Addressable partial for htmx |
| `{% set x = expr %}` | Bind a variable in current scope |
| `{% include "name" %}` | Render a registered component |
| `{# comment #}` | Stripped at parse time |

Expressions support paths (`user.name`, `items[0]`, `ctx["key"]`), literals, comparisons, boolean ops, and pipe filters (`{{ x | upper }}`, `{{ x | default("—") }}`). Built-in filters: `escape`, `raw`, `upper`, `lower`, `default`, `length`, `join`.

## htmx integration

`{% fragment name %}...{% endfragment %}` blocks are addressable on their own. Render a full page on the initial GET, then return just the changed fragment for subsequent htmx swaps:

```wren
var page = Template.parse(...)

// Full page render:
return page.render({ "user": user })

// Partial update (htmx-triggered):
return page.renderFragment("user-card", { "user": user })
```

`Hx.response(body)` builds an HTTP response shape with the right `HX-*` headers — chain `.trigger("name")`, `.redirect(url)`, `.swap("outerHTML")` to build progressive-enhancement responses without hand-formatting headers. Templates can also detect htmx requests via `ctx["#hx"]` (exposed as `hx` in expressions).

> **Tip — escape by default**
> `{{ }}` HTML-escapes its input, so user-supplied values are safe in attribute and text contexts. Use `{{{ }}}` only for content you've explicitly rendered through another template or sanitised. Don't disable escaping globally; that's a footgun without a corresponding upside.

## Compatibility

Wren 0.4 + WrenLift runtime 0.1 or newer. Pure-Wren — no native dependencies. Pairs with `@hatch:http` for serving HTML responses and `@hatch:web` for rendering into a `Document` on the client.
