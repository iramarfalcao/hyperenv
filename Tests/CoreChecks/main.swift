// Verification harness for the pure Core layer.
// Compiled together with the Core sources via swiftc; not part of the app target.

import Foundation

var failures: [String] = []
var passed = 0

@MainActor func check(_ label: String, _ actual: String, _ expected: String) {
    if actual == expected { passed += 1 }
    else {
        failures.append("""
        FAIL \(label)
             expected: \(expected.debugDescription)
             actual:   \(actual.debugDescription)
        """)
    }
}

@MainActor func check(_ label: String, _ condition: Bool) {
    if condition { passed += 1 } else { failures.append("FAIL \(label)") }
}

// MARK: - GuardedBlock

let body = SessionScriptRenderer.hookBody(sessionPath: "$HOME/.config/hyperenv/session.zsh")
let M = BlockMarkers.v1

// 1. Empty file: no leading blank line.
let onEmpty = try! GuardedBlock.install(into: "", body: body)
check("install/empty has no leading blank", !onEmpty.hasPrefix("\n"))
check("install/empty ends with newline", onEmpty.hasSuffix("\n"))

// 2. Existing content without trailing newline.
let original = "eval \"$(/opt/homebrew/bin/brew shellenv zsh)\""
let installed = try! GuardedBlock.install(into: original, body: body)
check("install/appends after content", installed.hasPrefix(original))
check("install/inserts one blank separator", installed.contains(original + "\n\n" + M.begin))

// 3. Idempotence — the property that matters most.
let twice = try! GuardedBlock.install(into: installed, body: body)
check("install/idempotent", twice, installed)

// 4. Round trip must be byte-identical.
let removed = try! GuardedBlock.remove(from: installed)
check("remove/restores original exactly", removed, original)

// 5. Round trip when the file already ended with a newline.
let withNL = original + "\n"
check("remove/round-trips trailing newline",
      try! GuardedBlock.remove(from: try! GuardedBlock.install(into: withNL, body: body)), withNL)

// 6. CRLF must survive.
let crlf = "line one\r\nline two\r\n"
let crlfInstalled = try! GuardedBlock.install(into: crlf, body: body)
check("install/preserves CRLF", crlfInstalled.contains("\r\n") && !crlfInstalled.contains("\n\n"))
check("remove/round-trips CRLF", try! GuardedBlock.remove(from: crlfInstalled), crlf)

// 7. Block in the middle is replaced in place, not moved to the end.
let middle = "before\n\n\(M.begin)\nOLD\n\(M.end)\n\nafter\n"
let replaced = try! GuardedBlock.install(into: middle, body: ["NEW"])
check("install/replaces in place", replaced, "before\n\n\(M.begin)\nNEW\n\(M.end)\n\nafter\n")

// 8. Marker-looking text inside a user comment must not be detected.
let decoy = "# do not touch the # >>> hyperenv managed block thing\n"
check("findSpan/ignores marker inside a comment", !GuardedBlock.containsBlock(decoy))

// 9. Malformed states must refuse rather than guess.
@MainActor func throwsError(_ label: String, _ work: () throws -> Void) {
    do { try work(); failures.append("FAIL \(label) — expected a throw") } catch { passed += 1 }
}
throwsError("unbalanced/begin without end") {
    _ = try GuardedBlock.install(into: "\(M.begin)\nx\n", body: body)
}
throwsError("unbalanced/end without begin") {
    _ = try GuardedBlock.install(into: "\(M.end)\n", body: body)
}
throwsError("unbalanced/duplicate blocks") {
    _ = try GuardedBlock.install(into: "\(M.begin)\n\(M.end)\n\(M.begin)\n\(M.end)\n", body: body)
}
throwsError("unbalanced/end before begin") {
    _ = try GuardedBlock.install(into: "\(M.end)\n\(M.begin)\n", body: body)
}

// 10. A file with no block is returned untouched by remove.
check("remove/no block is a no-op", try! GuardedBlock.remove(from: original), original)

// MARK: - ShellQuoting + round trip through DotenvCodec

let nasty: [String] = [
    "simple",
    "with spaces",
    "it's",
    "quote\" and 'single'",
    "dollar $HOME and `backtick`",
    "hash # not a comment",
    "back\\slash",
    "multi\nline\nvalue",
    "",
    "trailing space ",
    "#leading hash",
    "a'b'c",
    "$(rm -rf /)",
]

for raw in nasty {
    let quoted = ShellQuoting.singleQuote(raw)
    var set = EnvSet()
    set[EnvKey("V")!] = EnvValue(raw)
    let (text, diags) = DotenvCodec.encode(set, dialect: .posixShell)
    let back = DotenvCodec.decode(text)
    check("roundtrip posix \(raw.debugDescription) no errors", !back.hasErrors && diags.isEmpty)
    check("roundtrip posix \(raw.debugDescription)",
          back.envSet[EnvKey("V")!]?.rawValue ?? "<missing>", raw)
    _ = quoted
}

for raw in nasty {
    var set = EnvSet()
    set[EnvKey("V")!] = EnvValue(raw)
    let (text, _) = DotenvCodec.encode(set, dialect: .dotenv)
    let back = DotenvCodec.decode(text)
    check("roundtrip dotenv \(raw.debugDescription)",
          back.envSet[EnvKey("V")!]?.rawValue ?? "<missing>", raw)
}

// MARK: - Dotenv parsing specifics

func decodeOne(_ text: String) -> String? {
    DotenvCodec.decode(text).envSet[EnvKey("K")!]?.rawValue
}

check("parse/shell escaped quote run", decodeOne("K='it'\\''s'") ?? "", "it's")
check("parse/adjacent quoted runs", decodeOne("K='a'\"b\"") ?? "", "ab")
check("parse/bare strips trailing comment", decodeOne("K=value # trailing") ?? "", "value")
check("parse/hash without space is kept", decodeOne("K=abc#def") ?? "", "abc#def")
check("parse/export prefix accepted", decodeOne("export K=v") ?? "", "v")
check("parse/double quote escapes", decodeOne("K=\"a\\nb\"") ?? "", "a\nb")
check("parse/single quotes are literal", decodeOne("K='a\\nb'") ?? "", "a\\nb")
check("parse/empty value", decodeOne("K=") ?? "<nil>", "")
check("parse/multiline single quoted", decodeOne("K='line1\nline2'") ?? "", "line1\nline2")

let spaced = DotenvCodec.decode("K = v")
check("parse/space around = warns", spaced.diagnostics.contains { $0.severity == .warning })
check("parse/space around = still parses", spaced.envSet[EnvKey("K")!]?.rawValue ?? "", "v")

let badKey = DotenvCodec.decode("9BAD=x\nGOOD=y")
check("parse/invalid key rejected per row", badKey.entries.count == 1)
check("parse/invalid key keeps the good row", badKey.envSet[EnvKey("GOOD")!]?.rawValue ?? "", "y")
check("parse/invalid key reports error", badKey.diagnostics.contains { $0.severity == .error })

let dupes = DotenvCodec.decode("K=first\nK=second")
check("parse/duplicate last wins", dupes.envSet[EnvKey("K")!]?.rawValue ?? "", "second")
check("parse/duplicate warns", dupes.diagnostics.contains { $0.severity == .warning })

let unterminated = DotenvCodec.decode("K='oops")
check("parse/unterminated quote errors", unterminated.hasErrors)

let comments = DotenvCodec.decode("# header\n\n  # indented\nK=v\n")
check("parse/comments and blanks skipped", comments.entries.count == 1)

let crlfEnv = DotenvCodec.decode("A=1\r\nB=2\r\n")
check("parse/CRLF normalised", crlfEnv.entries.count == 2 && crlfEnv.envSet[EnvKey("B")!]?.rawValue == "2")

let bom = DotenvCodec.decode("\u{FEFF}K=v")
check("parse/BOM stripped", bom.envSet[EnvKey("K")!]?.rawValue ?? "", "v")

let noEquals = DotenvCodec.decode("JUST_A_WORD\nK=v")
check("parse/line without = errors but continues", noEquals.entries.count == 1 && noEquals.hasErrors)

// Docker dialect refuses newlines rather than silently corrupting.
var nl = EnvSet(); nl[EnvKey("K")!] = EnvValue("a\nb")
let dockerOut = DotenvCodec.encode(nl, dialect: .docker)
check("encode/docker rejects newline", dockerOut.diagnostics.contains { $0.severity == .error })

// Deterministic ordering.
var many = EnvSet()
for name in ["ZED", "ALPHA", "MIKE"] { many[EnvKey(name)!] = EnvValue("x") }
let (ordered, _) = DotenvCodec.encode(many, dialect: .posixShell)
check("encode/sorted key order",
      ordered.contains("ALPHA") && ordered.range(of: "ALPHA")!.lowerBound < ordered.range(of: "MIKE")!.lowerBound
      && ordered.range(of: "MIKE")!.lowerBound < ordered.range(of: "ZED")!.lowerBound)

// MARK: - EnvKey validation

check("key/rejects leading digit", EnvKey("1ABC") == nil)
check("key/rejects dash", EnvKey("A-B") == nil)
check("key/rejects empty", EnvKey("") == nil)
check("key/rejects space", EnvKey("A B") == nil)
check("key/accepts underscore lead", EnvKey("_A1") != nil)

// MARK: - PriorState codec: empty must not collapse to unset

let states: [PriorState] = [.absent, .present(EnvValue("")), .present(EnvValue("x"))]
for state in states {
    let data = try! JSONEncoder().encode(state)
    let back = try! JSONDecoder().decode(PriorState.self, from: data)
    check("priorState/round-trips \(state)", back == state)
}
check("priorState/empty differs from absent", PriorState.present(EnvValue("")) != PriorState.absent)

// MARK: - Session script

var sessionVars = EnvSet()
sessionVars[EnvKey("API_URL")!] = EnvValue("https://x.test/#frag")
sessionVars[EnvKey("TOKEN")!] = EnvValue("it's secret")
let session = SessionScriptRenderer.renderSession(
    variables: sessionVars, projectName: "P", profileName: "dev", appliedAt: "now")
check("session/has bypass guard before exports",
      session.range(of: "HYPERENV_DISABLE")!.lowerBound < session.range(of: "export API_URL")!.lowerBound)
check("session/quotes tricky values", session.contains("export TOKEN='it'\\''s secret'"))

let inverse = SessionScriptRenderer.renderInverse(
    restoring: [(EnvKey("A")!, .absent), (EnvKey("B")!, .present(EnvValue("old")))], appliedAt: "now")
check("inverse/unsets previously absent", inverse.contains("unset A"))
check("inverse/restores previous value", inverse.contains("export B='old'"))

// MARK: - Reconciler: the capture-once invariant

func key(_ name: String) -> EnvKey { EnvKey(name)! }
func envSet(_ pairs: [String: String]) -> EnvSet {
    var set = EnvSet()
    for (name, value) in pairs { set[key(name)] = EnvValue(value) }
    return set
}

// The user's real environment, measured with HyperEnv bypassed.
let userEnv = envSet(["API_URL": "https://prod.example", "KEEP": "untouched"])

// Apply profile A, which overrides API_URL and introduces NEW_VAR.
let planA = Reconciler.plan(
    desired: envSet(["API_URL": "https://dev.example", "NEW_VAR": "1"]),
    managed: ManagedState(),
    observed: userEnv)

check("plan/captures existing value as baseline",
      planA.captures[key("API_URL")] == .present(EnvValue("https://prod.example")))
check("plan/captures absent for a brand new key",
      planA.captures[key("NEW_VAR")] == .absent)
check("plan/does not touch unrelated keys", planA.captures[key("KEEP")] == nil)

// Now apply profile B over A. The environment a probe would see has already
// been mutated by A — re-capturing here is the classic bug.
let pollutedEnv = envSet(["API_URL": "https://dev.example", "KEEP": "untouched", "NEW_VAR": "1"])
let planB = Reconciler.plan(
    desired: envSet(["API_URL": "https://hml.example", "NEW_VAR": "2"]),
    managed: planA.resultingState,
    observed: pollutedEnv)

check("plan/does not re-capture an already managed key", planB.captures.isEmpty)
check("plan/baseline survives a second apply",
      planB.resultingState.baseline(for: key("API_URL")) == .present(EnvValue("https://prod.example")))

// Un-applying after two stacked applies must reach the *user's* original value,
// never profile A's intermediate one.
let undo = Reconciler.unapplyPlan(managed: planB.resultingState)
check("unapply/restores the true original, not the intermediate",
      undo.restores[key("API_URL")] == .present(EnvValue("https://prod.example")))
check("unapply/unsets keys that never existed",
      undo.restores[key("NEW_VAR")] == .absent)
check("unapply/leaves nothing managed", undo.resultingState.isEmpty)

// Dropping a key from the desired set hands it back immediately.
let planC = Reconciler.plan(
    desired: envSet(["API_URL": "https://hml.example"]),
    managed: planB.resultingState,
    observed: pollutedEnv)
check("plan/releases a dropped key", planC.restores[key("NEW_VAR")] == .absent)
check("plan/dropped key is no longer managed", !planC.resultingState.isManaged(key("NEW_VAR")))
check("plan/retained key stays managed", planC.resultingState.isManaged(key("API_URL")))

// An empty-string baseline must not degrade into "unset".
let emptyBaseline = Reconciler.plan(
    desired: envSet(["E": "x"]), managed: ManagedState(), observed: envSet(["E": ""]))
check("plan/empty string is a real baseline",
      emptyBaseline.captures[key("E")] == .present(EnvValue("")))
check("plan/empty baseline is not absent", emptyBaseline.captures[key("E")] != .absent)

// Semantic drift: the failure a checksum cannot see.
let drift = Reconciler.semanticDrift(
    expected: envSet(["A": "1", "B": "2", "C": "3"]),
    observed: envSet(["A": "1", "B": "shadowed"]))
check("drift/clean key reports nothing", drift[key("A")] == nil)
check("drift/detects a shadowed value",
      drift[key("B")] == .shadowed(expected: EnvValue("2"), actual: EnvValue("shadowed")))
check("drift/detects a missing value", drift[key("C")] == .missing(expected: EnvValue("3")))

// MARK: - SeedFilter

check("seed/PATH is path-like", SeedFilter.classify(key: key("PATH"), value: "/usr/bin") == .pathLike)
check("seed/unknown *PATH with colons is path-like",
      SeedFilter.classify(key: key("GOPATH"), value: "/a:/b") == .pathLike)
check("seed/TMPDIR is session scoped",
      SeedFilter.classify(key: key("TMPDIR"), value: "/var/folders/x") == .session)
check("seed/SSH_AUTH_SOCK is session scoped",
      SeedFilter.classify(key: key("SSH_AUTH_SOCK"), value: "/var/run/x") == .session)
check("seed/HOMEBREW_ is derived",
      SeedFilter.classify(key: key("HOMEBREW_PREFIX"), value: "/opt/homebrew") == .derived)
check("seed/DYLD_ is rejected",
      SeedFilter.classify(key: key("DYLD_LIBRARY_PATH"), value: "/x") == .rejected)
check("seed/__CF noise is cosmetic",
      SeedFilter.classify(key: key("__CFBundleIdentifier"), value: "x") == .cosmetic)
check("seed/HOME is not ours to manage",
      SeedFilter.classify(key: key("HOME"), value: "/Users/x") == .session)
check("seed/a real variable is importable",
      SeedFilter.classify(key: key("MY_API_TOKEN"), value: "abc") == .user)

// Base subtraction: identical inherited values drop out, changed ones stay.
let classified = SeedFilter.classify(
    observed: envSet(["HOME": "/Users/x", "LANG": "en_US.UTF-8", "MY_VAR": "v", "TERM": "xterm"]),
    base: envSet(["HOME": "/Users/x", "LANG": "C"]))
check("seed/drops values identical to the base", !classified.importable.contains(key("HOME")))
check("seed/keeps values the shell changed", classified.importable.contains(key("LANG")))
check("seed/keeps genuinely new variables", classified.importable.contains(key("MY_VAR")))
check("seed/buckets terminal noise away from imports", !classified.importable.contains(key("TERM")))
check("seed/noise is retained in its bucket", classified.set(for: .cosmetic).contains(key("TERM")))

// MARK: - Report

print("passed: \(passed)")
if failures.isEmpty {
    print("ALL CHECKS PASSED")
} else {
    print("\nfailures: \(failures.count)\n")
    for failure in failures { print(failure) }
    exit(1)
}
