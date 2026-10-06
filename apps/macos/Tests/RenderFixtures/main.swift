// Renders real HyperEnv artefacts into a directory, using the production
// renderer, so the integration script can exercise them with a real zsh.
//
// Usage: renderfixtures <output-dir>

import Foundation

let outputDirectory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: ".")

func write(_ text: String, _ name: String) {
    let url = outputDirectory.appending(path: name)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}

// A dotfile the user already had, setting a variable HyperEnv will override.
let userZprofile = """
export PRE_EXISTING='original value'
export UNTOUCHED='leave me alone'
export EMPTY_ONE=
"""

// The profile being applied: overrides one existing key, adds a new one.
var desired = EnvSet()
desired[EnvKey("PRE_EXISTING")!] = EnvValue("applied value")
desired[EnvKey("BRAND_NEW")!] = EnvValue("hello world")
desired[EnvKey("TRICKY")!] = EnvValue("it's got $DOLLAR and #hash")
desired[EnvKey("EMPTY_ONE")!] = EnvValue("now set")

// What the shell looked like before HyperEnv touched it.
var observed = EnvSet()
observed[EnvKey("PRE_EXISTING")!] = EnvValue("original value")
observed[EnvKey("UNTOUCHED")!] = EnvValue("leave me alone")
observed[EnvKey("EMPTY_ONE")!] = EnvValue("")

let plan = Reconciler.plan(desired: desired, managed: ManagedState(), observed: observed)

write(SessionScriptRenderer.renderSession(
    variables: plan.exports, projectName: "Test", profileName: "dev", appliedAt: "fixture"),
    "session.zsh")

write(SessionScriptRenderer.renderInverse(
    restoring: plan.inverseEntries(), appliedAt: "fixture"),
    "unsession.zsh")

// The user's dotfile with our guarded block installed.
let sessionPath = outputDirectory.appending(path: "session.zsh").path
let hooked = try! GuardedBlock.install(
    into: userZprofile,
    body: SessionScriptRenderer.hookBody(sessionPath: sessionPath))
write(hooked, ".zprofile")

// The same dotfile with the block removed again, to prove the round trip.
write(try! GuardedBlock.remove(from: hooked), "zprofile.restored")
write(userZprofile, "zprofile.original")

print("rendered into \(outputDirectory.path)")
