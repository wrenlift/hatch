// @hatch:cli — clap-style argument parser.
//
// Usage:
//
//   import "@hatch:cli" for Cli, Arg
//
//   var app = Cli.new("greet")
//     .version("0.1.0")
//     .about("Prints a greeting")
//     .arg(Arg.new("name").positional().required()
//           .help("who to greet"))
//     .arg(Arg.new("loud").short("l").long("loud").flag()
//           .help("shout the greeting"))
//     .arg(Arg.new("count").short("n").long("count").value().default("1")
//           .help("how many times"))
//
//   var m = app.parse(argv)
//   if (m.error != null) {
//     System.print(m.error)
//     return
//   }
//   var name = m.value("name")
//   var loud = m.flag("loud")
//
// Shape follows clap (the Rust crate): a fluent builder where
// Arg configures a single switch / option / positional and Cli
// collects them, generates help + version text, and does parsing.
//
// Errors are returned via Matches.error rather than thrown, so a
// main function can decide whether to print-and-exit or retry.
// Help / version also populate error with the rendered text;
// helpRequested / versionRequested distinguish those from real
// mistakes.

// --- Arg --------------------------------------------------------------------

class Arg {
  construct new(name) {
    _name = name
    _short = null
    _long = null
    _help = null
    _takesValue = false
    _positional = false
    _required = false
    _default = null
    _count = false
  }

  // Builder setters -- each returns `this` for chaining.
  // flag/value/count/positional are mutually exclusive kinds; the
  // last one called wins.

  short(s) {
    _short = s
    return this
  }

  long(l) {
    _long = l
    return this
  }

  help(h) {
    _help = h
    return this
  }

  // Takes a value: --key val / -k val / --key=val.
  value() {
    _takesValue = true
    _count = false
    _positional = false
    return this
  }

  // Boolean flag: presence sets it to true.
  flag() {
    _takesValue = false
    _count = false
    _positional = false
    return this
  }

  // Counting flag: each occurrence bumps a counter (-v -v -v -> 3).
  count() {
    _takesValue = false
    _count = true
    _positional = false
    return this
  }

  // Positional -- consumed by slot in declaration order. Always
  // takes a value (by definition), so value() is implicit.
  positional() {
    _positional = true
    _takesValue = true
    _count = false
    return this
  }

  required() {
    _required = true
    return this
  }

  default(v) {
    _default = v
    _takesValue = true
    return this
  }

  // Getters used by Cli.
  name           { _name }
  shortFlag      { _short }
  longFlag       { _long }
  helpText       { _help }
  takesValue     { _takesValue }
  isPositional   { _positional }
  isRequired     { _required }
  defaultVal     { _default }
  isCount        { _count }
}

// --- Cli --------------------------------------------------------------------

class Cli {
  construct new(name) {
    _name = name
    _about = null
    _version = null
    _args = []
    _positionals = []
    _longIndex = {}
    _shortIndex = {}
    _subcommands = {}
  }

  about(a) {
    _about = a
    return this
  }

  version(v) {
    _version = v
    return this
  }

  // Store each arg once plus build side-indexes for constant-time
  // lookups during parsing.
  arg(a) {
    _args.add(a)
    if (a.isPositional) _positionals.add(a)
    if (a.longFlag != null) _longIndex[a.longFlag] = a
    if (a.shortFlag != null) _shortIndex[a.shortFlag] = a
    return this
  }

  subcommand(c) {
    _subcommands[c.cliName_] = c
    return this
  }

  cliName_       { _name }
  about_         { _about }
  version_       { _version }
  args_          { _args }
  subs_          { _subcommands }

  // Parse argv (a list of strings) and return a Matches. Errors
  // populate matches.error; parsing still returns a Matches so
  // callers can inspect whatever was parsed before the failure.
  parse(argv) {
    var matches = Matches.new()
    var argvCount = argv.count

    // --help / --version short-circuit before any other parsing.
    var h = 0
    while (h < argvCount) {
      var t = argv[h]
      if (t == "--help" || t == "-h") {
        matches.error_ = renderHelp_()
        matches.helpRequested_ = true
        return matches
      }
      if (t == "--version" || t == "-V") {
        matches.error_ = renderVersion_()
        matches.versionRequested_ = true
        return matches
      }
      h = h + 1
    }

    // Subcommand dispatch: if the first non-flag token matches a
    // registered subcommand name, hand the rest off to it.
    var rootEnd = argvCount
    if (_subcommands.count > 0) {
      var i = 0
      while (i < argvCount) {
        var t = argv[i]
        if (t.count > 0 && t[0] != "-" && _subcommands.containsKey(t)) {
          rootEnd = i
          break
        }
        if (t.count > 0 && t[0] == "-") {
          if (consumesNext_(t)) i = i + 1
        }
        i = i + 1
      }
    }

    var rootArgv = argv[0...rootEnd]
    parseInto_(matches, rootArgv)
    if (matches.error_ != null) return matches

    if (rootEnd < argvCount) {
      var subName = argv[rootEnd]
      var subArgv = argv[(rootEnd + 1)...argvCount]
      var subMatches = _subcommands[subName].parse(subArgv)
      matches.sub_ = [subName, subMatches]
    }
    return matches
  }

  // --- Internals --------------------------------------------------------

  consumesNext_(tok) {
    if (tok.contains("=")) return false
    if (tok.startsWith("--")) {
      var name = tok[2...tok.count]
      var a = findLong_(name)
      return a != null && a.takesValue
    }
    if (tok.startsWith("-") && tok.count > 1) {
      var s = tok[1...2]
      var a = findShort_(s)
      return a != null && a.takesValue
    }
    return false
  }

  parseInto_(matches, argv) {
    // `_positionals` was built at `arg()` time, so the parse loop
    // can consume it directly instead of scanning `_args` here.
    var positional = _positionals
    var positionalIdx = 0

    var i = 0
    var passthrough = false
    while (i < argv.count) {
      var tok = argv[i]

      if (tok == "--") {
        passthrough = true
        i = i + 1
        continue
      }

      if (!passthrough && tok.startsWith("-") && tok.count > 1) {
        if (tok.startsWith("--")) {
          i = handleLong_(matches, argv, i)
        } else {
          i = handleShort_(matches, argv, i)
        }
        if (matches.error_ != null) return
        continue
      }

      if (positionalIdx >= positional.count) {
        matches.error_ = "unexpected positional argument: %(tok)"
        return
      }
      var a = positional[positionalIdx]
      matches.values_[a.name] = tok
      positionalIdx = positionalIdx + 1
      i = i + 1
    }

    applyDefaults_(matches)
    validateRequired_(matches)
  }

  handleLong_(matches, argv, i) {
    var tok = argv[i]
    var body = tok[2...tok.count]
    var eqIdx = indexOf_(body, "=")
    var flagName = eqIdx >= 0 ? body[0...eqIdx] : body
    var inlineValue = eqIdx >= 0 ? body[(eqIdx + 1)...body.count] : null
    var a = findLong_(flagName)
    if (a == null) {
      matches.error_ = "unknown flag: --%(flagName)"
      return i + 1
    }
    return applyArg_(matches, argv, i, a, inlineValue, "--%(flagName)")
  }

  handleShort_(matches, argv, i) {
    var tok = argv[i]
    var body = tok[1...tok.count]
    // v0.1 accepts `-k`, `-kval`, and `-k val`. No grouping (`-abc`).
    var shortKey = body[0...1]
    var a = findShort_(shortKey)
    if (a == null) {
      matches.error_ = "unknown flag: -%(shortKey)"
      return i + 1
    }
    var inlineValue = body.count > 1 ? body[1...body.count] : null
    return applyArg_(matches, argv, i, a, inlineValue, "-%(shortKey)")
  }

  applyArg_(matches, argv, i, a, inlineValue, tokLabel) {
    if (a.isCount) {
      var prev = matches.counts_.containsKey(a.name) ? matches.counts_[a.name] : 0
      matches.counts_[a.name] = prev + 1
      return i + 1
    }
    if (a.takesValue) {
      if (inlineValue == null) {
        if (i + 1 >= argv.count) {
          matches.error_ = "%(tokLabel) requires a value"
          return i + 1
        }
        matches.values_[a.name] = argv[i + 1]
        return i + 2
      }
      matches.values_[a.name] = inlineValue
      return i + 1
    }
    matches.flags_[a.name] = true
    return i + 1
  }

  applyDefaults_(matches) {
    var i = 0
    while (i < _args.count) {
      var a = _args[i]
      if (a.takesValue && a.defaultVal != null && !matches.values_.containsKey(a.name)) {
        matches.values_[a.name] = a.defaultVal
      }
      i = i + 1
    }
  }

  validateRequired_(matches) {
    var i = 0
    while (i < _args.count) {
      var a = _args[i]
      if (a.isRequired) {
        var missing = false
        if (a.takesValue) {
          missing = !matches.values_.containsKey(a.name)
        } else if (a.isCount) {
          missing = !matches.counts_.containsKey(a.name)
        } else {
          missing = !matches.flags_.containsKey(a.name)
        }
        if (missing) {
          var kind = a.takesValue ? "argument" : "flag"
          matches.error_ = "missing required %(kind): %(a.name)"
          return
        }
      }
      i = i + 1
    }
  }

  findLong_(name) {
    return _longIndex.containsKey(name) ? _longIndex[name] : null
  }

  findShort_(name) {
    return _shortIndex.containsKey(name) ? _shortIndex[name] : null
  }

  // --- Help / version ---------------------------------------------------

  renderVersion_() {
    var v = _version == null ? "(no version set)" : _version
    return "%(_name) %(v)"
  }

  renderHelp_() {
    var lines = []
    var header = _version == null ? _name : "%(_name) %(_version)"
    lines.add(header)
    if (_about != null) {
      lines.add("")
      lines.add(_about)
    }
    lines.add("")
    lines.add("USAGE:")
    var usage = "  %(_name)"
    if (_args.any { |a| !a.isPositional }) usage = usage + " [OPTIONS]"
    for (a in _args) {
      if (a.isPositional) {
        usage = usage + (a.isRequired ? " <%(a.name)>" : " [%(a.name)]")
      }
    }
    if (_subcommands.count > 0) usage = usage + " <SUBCOMMAND>"
    lines.add(usage)

    var options = []
    var positionals = []
    for (a in _args) {
      if (a.isPositional) {
        positionals.add(a)
      } else {
        options.add(a)
      }
    }

    if (positionals.count > 0) {
      lines.add("")
      lines.add("ARGS:")
      for (a in positionals) {
        var label = "<%(a.name)>"
        var desc = a.helpText == null ? "" : a.helpText
        lines.add("  %(padRight_(label, 20))  %(desc)")
      }
    }

    if (options.count > 0) {
      lines.add("")
      lines.add("OPTIONS:")
      for (a in options) {
        var parts = []
        if (a.shortFlag != null) parts.add("-%(a.shortFlag)")
        if (a.longFlag != null) parts.add("--%(a.longFlag)")
        if (a.takesValue) parts.add("<%(a.name)>")
        var label = parts.join(" ")
        var desc = a.helpText == null ? "" : a.helpText
        lines.add("  %(padRight_(label, 20))  %(desc)")
      }
    }

    if (_subcommands.count > 0) {
      lines.add("")
      lines.add("SUBCOMMANDS:")
      for (entry in _subcommands) {
        var desc = entry.value.about_ == null ? "" : entry.value.about_
        lines.add("  %(padRight_(entry.key, 20))  %(desc)")
      }
    }
    return lines.join("\n")
  }

  indexOf_(s, ch) {
    var i = 0
    while (i < s.count) {
      if (s[i] == ch) return i
      i = i + 1
    }
    return -1
  }

  padRight_(s, width) {
    if (s.count >= width) return s
    return s + " " * (width - s.count)
  }
}

// --- Matches ----------------------------------------------------------------

class Matches {
  construct new() {
    _flags = {}
    _values = {}
    _counts = {}
    _sub = null
    _error = null
    _helpRequested = false
    _versionRequested = false
  }

  // User-facing accessors.
  flag(name)    { _flags.containsKey(name) && _flags[name] == true }
  value(name)   { _values.containsKey(name) ? _values[name] : null }
  count(name)   { _counts.containsKey(name) ? _counts[name] : 0 }
  subcommand    { _sub }
  error         { _error }
  helpRequested { _helpRequested }
  versionRequested { _versionRequested }

  // Parse-internal setters (trailing underscore keeps them distinct
  // from the user-facing getters above).
  flags_        { _flags }
  values_       { _values }
  counts_       { _counts }
  sub_=(v)      { _sub = v }
  error_        { _error }
  error_=(v)    { _error = v }
  helpRequested_=(v)    { _helpRequested = v }
  versionRequested_=(v) { _versionRequested = v }
}
