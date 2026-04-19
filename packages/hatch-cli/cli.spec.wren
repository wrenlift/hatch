import "./cli" for Cli, Arg
import "@hatch:test" for Test
import "@hatch:assert" for Expect

// Helper: build a small app we reuse across tests.
var newApp = Fn.new {
  return Cli.new("greet")
    .version("0.1.0")
    .about("Prints a greeting")
    .arg(Arg.new("name").positional().required().help("who to greet"))
    .arg(Arg.new("loud").short("l").long("loud").flag().help("shout"))
    .arg(Arg.new("count").short("n").long("count").value().default("1"))
    .arg(Arg.new("verbose").short("v").count().help("repeat for more output"))
}

Test.describe("positional args") {
  Test.it("required positional is picked up") {
    var m = newApp.call().parse(["alice"])
    Expect.that(m.error).toBeNull()
    Expect.that(m.value("name")).toBe("alice")
  }
  Test.it("missing required positional is an error") {
    var m = newApp.call().parse([])
    Expect.that(m.error).toContain("missing required argument: name")
  }
  Test.it("extra positional is an error") {
    var m = newApp.call().parse(["alice", "bob"])
    Expect.that(m.error).toContain("unexpected positional")
  }
}

Test.describe("flags") {
  Test.it("long form sets the flag") {
    var m = newApp.call().parse(["alice", "--loud"])
    Expect.that(m.flag("loud")).toBeTruthy()
  }
  Test.it("short form sets the flag") {
    var m = newApp.call().parse(["alice", "-l"])
    Expect.that(m.flag("loud")).toBeTruthy()
  }
  Test.it("absent flag reads false") {
    var m = newApp.call().parse(["alice"])
    Expect.that(m.flag("loud")).toBe(false)
  }
}

Test.describe("value options") {
  Test.it("--key value (space-separated)") {
    var m = newApp.call().parse(["alice", "--count", "3"])
    Expect.that(m.value("count")).toBe("3")
  }
  Test.it("--key=value (inline)") {
    var m = newApp.call().parse(["alice", "--count=3"])
    Expect.that(m.value("count")).toBe("3")
  }
  Test.it("-k value (short, space)") {
    var m = newApp.call().parse(["alice", "-n", "3"])
    Expect.that(m.value("count")).toBe("3")
  }
  Test.it("-kval (short, inline)") {
    var m = newApp.call().parse(["alice", "-n3"])
    Expect.that(m.value("count")).toBe("3")
  }
  Test.it("default applies when unset") {
    var m = newApp.call().parse(["alice"])
    Expect.that(m.value("count")).toBe("1")
  }
  Test.it("missing value for --key errors") {
    var m = newApp.call().parse(["alice", "--count"])
    Expect.that(m.error).toContain("requires a value")
  }
}

Test.describe("counting flags") {
  Test.it("zero occurrences reads 0") {
    var m = newApp.call().parse(["alice"])
    Expect.that(m.count("verbose")).toBe(0)
  }
  Test.it("multiple occurrences sum") {
    var m = newApp.call().parse(["alice", "-v", "-v", "-v"])
    Expect.that(m.count("verbose")).toBe(3)
  }
}

Test.describe("unknown flags") {
  Test.it("unknown long") {
    var m = newApp.call().parse(["alice", "--nope"])
    Expect.that(m.error).toContain("unknown flag: --nope")
  }
  Test.it("unknown short") {
    var m = newApp.call().parse(["alice", "-X"])
    Expect.that(m.error).toContain("unknown flag: -X")
  }
}

Test.describe("-- passthrough") {
  Test.it("tokens after -- become positional even if they look like flags") {
    var app = Cli.new("x")
      .arg(Arg.new("target").positional().required())
    var m = app.parse(["--", "--not-a-flag"])
    Expect.that(m.error).toBeNull()
    Expect.that(m.value("target")).toBe("--not-a-flag")
  }
}

Test.describe("help + version") {
  Test.it("--help fills error with rendered text") {
    var m = newApp.call().parse(["--help"])
    Expect.that(m.helpRequested).toBeTruthy()
    Expect.that(m.error).toContain("greet")
    Expect.that(m.error).toContain("USAGE")
  }
  Test.it("-h is the same as --help") {
    var m = newApp.call().parse(["-h"])
    Expect.that(m.helpRequested).toBeTruthy()
  }
  Test.it("--version prints name + version") {
    var m = newApp.call().parse(["--version"])
    Expect.that(m.versionRequested).toBeTruthy()
    Expect.that(m.error).toContain("greet 0.1.0")
  }
}

Test.describe("subcommands") {
  Test.it("dispatches to the named subcommand") {
    var app = Cli.new("tool")
      .subcommand(Cli.new("build")
        .arg(Arg.new("release").long("release").flag()))
      .subcommand(Cli.new("test")
        .arg(Arg.new("filter").positional()))
    var m = app.parse(["build", "--release"])
    Expect.that(m.error).toBeNull()
    Expect.that(m.subcommand[0]).toBe("build")
    Expect.that(m.subcommand[1].flag("release")).toBeTruthy()
  }
  Test.it("root-only invocation leaves subcommand null") {
    var app = Cli.new("tool")
      .subcommand(Cli.new("build"))
    var m = app.parse([])
    Expect.that(m.subcommand).toBeNull()
  }
}

Test.run()
