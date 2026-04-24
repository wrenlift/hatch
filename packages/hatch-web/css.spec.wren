import "./css"         for Css, Style, Stylesheet
import "@hatch:test"   for Test
import "@hatch:assert" for Expect

Test.describe("Css.tw — primitives") {
  Test.it("p-4 expands to padding: 1rem") {
    var s = Css.tw("p-4")
    Expect.that(s.css).toContain("padding: 1rem")
  }

  Test.it("p-0 stays '0' (no 0rem)") {
    var s = Css.tw("p-0")
    Expect.that(s.css).toContain("padding: 0")
    Expect.that(s.css).not.toContain("0rem")
  }

  Test.it("px-* sets both left and right") {
    var s = Css.tw("px-4")
    Expect.that(s.css).toContain("padding-left: 1rem")
    Expect.that(s.css).toContain("padding-right: 1rem")
  }

  Test.it("text size expands to font-size + line-height") {
    var s = Css.tw("text-lg")
    Expect.that(s.css).toContain("font-size: 1.125rem")
    Expect.that(s.css).toContain("line-height: 1.75rem")
  }

  Test.it("font-weight map") {
    var s = Css.tw("font-semibold")
    Expect.that(s.css).toContain("font-weight: 600")
  }

  Test.it("bg-color-shade") {
    var s = Css.tw("bg-blue-500")
    Expect.that(s.css).toContain("background-color: #3b82f6")
  }

  Test.it("text-color-shade sets color (not bg)") {
    var s = Css.tw("text-gray-700")
    Expect.that(s.css).toContain("color: #374151")
    Expect.that(s.css).not.toContain("background-color")
  }

  Test.it("border-color applied") {
    var s = Css.tw("border-red-300")
    Expect.that(s.css).toContain("border-color: #fca5a5")
  }

  Test.it("rounded default is md") {
    var s = Css.tw("rounded")
    Expect.that(s.css).toContain("border-radius: 0.375rem")
  }

  Test.it("rounded-full") {
    var s = Css.tw("rounded-full")
    Expect.that(s.css).toContain("border-radius: 9999px")
  }

  Test.it("flex layout cluster") {
    var s = Css.tw("flex items-center justify-between gap-4")
    Expect.that(s.css).toContain("display: flex")
    Expect.that(s.css).toContain("align-items: center")
    Expect.that(s.css).toContain("justify-content: space-between")
    Expect.that(s.css).toContain("gap: 1rem")
  }

  Test.it("unknown utility is silently ignored") {
    var s = Css.tw("p-4 this-is-not-a-real-utility text-red-500")
    Expect.that(s.css).toContain("padding: 1rem")
    Expect.that(s.css).toContain("color: #ef4444")
  }

  Test.it("empty string returns empty base rule") {
    var s = Css.tw("")
    Expect.that(s.css).toBe("")
  }
}

Test.describe("Css.tw — state prefixes") {
  Test.it("hover:bg-blue-600 lands on :hover") {
    var s = Css.tw("bg-blue-500 hover:bg-blue-600")
    Expect.that(s.css).toContain("background-color: #3b82f6")
    Expect.that(s.css).toContain(":hover")
    Expect.that(s.css).toContain("background-color: #2563eb")
  }

  Test.it("focus:text-blue-500 lands on :focus") {
    var s = Css.tw("focus:text-blue-500")
    Expect.that(s.css).toContain(":focus")
    Expect.that(s.css).toContain("color: #3b82f6")
  }

  Test.it("chain-style hover(style)") {
    var s = Css.tw("bg-white").hover(Css.tw("bg-gray-100"))
    Expect.that(s.css).toContain(":hover")
    Expect.that(s.css).toContain("background-color: #f3f4f6")
  }

  Test.it("chain-style hover(string)") {
    var s = Css.tw("bg-white").hover("bg-gray-100 text-gray-900")
    Expect.that(s.css).toContain(":hover")
    Expect.that(s.css).toContain("background-color: #f3f4f6")
    Expect.that(s.css).toContain("color: #111827")
  }
}

Test.describe("Css.tw — responsive") {
  Test.it("md:px-8 wraps in @media") {
    var s = Css.tw("md:px-8")
    Expect.that(s.css).toContain("@media (min-width: 768px)")
    Expect.that(s.css).toContain("padding-left: 2rem")
  }

  Test.it(".sm(\"flex\") chain") {
    var s = Css.tw("block").sm("flex")
    Expect.that(s.css).toContain("display: block")
    Expect.that(s.css).toContain("@media (min-width: 640px)")
  }
}

Test.describe("Style — class name & css") {
  Test.it("className is deterministic for identical styles") {
    var a = Css.tw("p-4 text-red-500")
    var b = Css.tw("text-red-500 p-4")  // different token order, same css
    Expect.that(a.className).toBe(b.className)
  }

  Test.it("different styles get different class names") {
    var a = Css.tw("p-4")
    var b = Css.tw("p-8")
    Expect.that(a.className).not.toBe(b.className)
  }

  Test.it("className is stable across calls") {
    var s = Css.tw("flex gap-2")
    Expect.that(s.className).toBe(s.className)
  }

  Test.it("className starts with 'c-' prefix") {
    var s = Css.tw("p-4")
    Expect.that(s.className.startsWith("c-")).toBe(true)
  }

  Test.it("styleTag wraps css in <style>") {
    var s = Css.tw("p-4")
    Expect.that(s.styleTag.startsWith("<style>")).toBe(true)
    Expect.that(s.styleTag.endsWith("</style>")).toBe(true)
    Expect.that(s.styleTag).toContain("padding: 1rem")
  }
}

Test.describe("Css.raw — arbitrary declarations") {
  Test.it("folds raw map into base") {
    var s = Css.raw({"mix-blend-mode": "multiply", "-webkit-appearance": "none"})
    Expect.that(s.css).toContain("mix-blend-mode: multiply")
    Expect.that(s.css).toContain("-webkit-appearance: none")
  }

  Test.it("raw composes with tw") {
    var s = Css.tw("p-4").raw({"clip-path": "circle(50%)"})
    Expect.that(s.css).toContain("padding: 1rem")
    Expect.that(s.css).toContain("clip-path: circle(50%)")
  }
}

Test.describe("Stylesheet — dedup & emit") {
  Test.it("add returns the style for threading") {
    var sheet = Css.sheet
    var btn = Css.tw("p-4")
    var ret = sheet.add(btn)
    Expect.that(ret).toBe(btn)
  }

  Test.it("count reflects unique styles only") {
    var sheet = Css.sheet
    sheet.add(Css.tw("p-4"))
    sheet.add(Css.tw("p-4"))  // same className — dedup
    sheet.add(Css.tw("p-8"))
    Expect.that(sheet.count).toBe(2)
  }

  Test.it("emit concatenates all styles") {
    var sheet = Css.sheet
    sheet.add(Css.tw("p-4"))
    sheet.add(Css.tw("text-red-500"))
    var out = sheet.emit
    Expect.that(out).toContain("padding: 1rem")
    Expect.that(out).toContain("color: #ef4444")
  }

  Test.it("empty styleTag is empty string, not <style></style>") {
    Expect.that(Css.sheet.styleTag).toBe("")
  }

  Test.it("non-empty styleTag wraps aggregate") {
    var sheet = Css.sheet
    sheet.add(Css.tw("p-4"))
    var tag = sheet.styleTag
    Expect.that(tag.startsWith("<style>")).toBe(true)
    Expect.that(tag).toContain("padding: 1rem")
  }
}

// Integration scenario: real usage pattern.
Test.describe("Css — realistic button") {
  Test.it("compiles a multi-state interactive button") {
    var btn = Css
      .tw("bg-blue-500 text-white px-4 py-2 rounded font-semibold")
      .hover("bg-blue-600")
      .focus("bg-blue-700")
      .disabled("bg-gray-300 text-gray-500")

    Expect.that(btn.css).toContain(".%(btn.className)")
    Expect.that(btn.css).toContain("background-color: #3b82f6")
    Expect.that(btn.css).toContain(":hover")
    Expect.that(btn.css).toContain("background-color: #2563eb")
    Expect.that(btn.css).toContain(":focus")
    Expect.that(btn.css).toContain(":disabled")
  }
}

Test.run()
