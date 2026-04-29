// Wren-side wrapper for the wlift_hello plugin. The foreign
// methods bind by `#!symbol = "<export-name>"` against the
// plugin's wasm exports; the loader resolves them on install.

#!native = "wlift_hello"
foreign class Hello {
  // Returns "hello, <name>". Falls back to "hello, stranger" when
  // the argument isn't a string.
  #!symbol = "wlift_hello_greet"
  foreign static greet(name)
}
