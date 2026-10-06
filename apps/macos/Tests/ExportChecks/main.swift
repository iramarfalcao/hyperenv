//
//  ExportChecks
//
//  Proves an export carries the variables it claims to.
//
//  This exists because exporting the snapshot profile produced a file with a
//  comment header and no variables at all. Every variable in that profile is
//  switched off — correctly, since replaying a search path or a session socket
//  into a shell would be wrong — and the exporter only ever wrote the
//  switched-on ones. The result looked like a successful export right up until
//  the file was opened.
//

import AppKit
import Foundation
import SwiftData

@MainActor
final class Checks {
    var passed = 0
    var failed = 0

    func expect(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
        } else {
            failed += 1
            print("FAIL \(label)")
            let extra = detail()
            if !extra.isEmpty { print("     \(extra)") }
        }
    }
}

/// The real Default profile, as seeded from a machine: everything switched off,
/// bucketed by why it is not safe to apply.
@MainActor
func snapshotProfile() -> (ModelContainer, Profile) {
    let schema = Schema([Project.self, Profile.self, EnvVariable.self])
    let container = try! ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    let context = container.mainContext

    let project = Project(name: "Default", isDefault: true, sortIndex: -1)
    context.insert(project)
    let profile = Profile(name: "Default", kind: .systemDefault, isDefault: true, sortIndex: 0)
    profile.project = project
    context.insert(profile)

    let seeded: [(String, String, SeedBucket)] = [
        ("PATH", "/opt/homebrew/bin:/usr/bin:/bin", .pathLike),
        ("FPATH", "/opt/homebrew/share/zsh/site-functions", .pathLike),
        ("HOMEBREW_PREFIX", "/opt/homebrew", .derived),
        ("PWD", "/", .session),
        ("SHLVL", "1", .cosmetic),
    ]
    for (index, entry) in seeded.enumerated() {
        let variable = EnvVariable(
            key: entry.0, value: entry.1,
            isEnabled: entry.2.isImportable,
            sortIndex: index, origin: .imported, bucket: entry.2)
        variable.profile = profile
        context.insert(variable)
    }
    try! context.save()
    return (container, profile)
}

let checks = Checks()
let (container, profile) = snapshotProfile()
_ = container

checks.expect(
    "the snapshot has variables but none switched on",
    profile.variables.count == 5 && profile.enabledVariableCount == 0,
    "count=\(profile.variables.count) enabled=\(profile.enabledVariableCount)")

// The bug: this scope is empty for a snapshot, and used to be written anyway.
let enabled = DotenvTransfer.variables(of: profile, scope: .enabledOnly)
checks.expect("switched-on scope is empty for a snapshot", enabled.isEmpty)

let everything = DotenvTransfer.variables(of: profile, scope: .everything)
checks.expect(
    "all-variables scope carries every one",
    everything.count == 5,
    "carried \(everything.count) of 5")

let transfer = DotenvTransfer()

// No file is produced for an empty scope, and the user is told why.
let empty = transfer.exportText(profile: profile, dialect: .posixShell, scope: .enabledOnly)
checks.expect("an empty scope writes no file", empty == nil)
checks.expect(
    "and explains itself",
    transfer.showsAlert && transfer.alertMessage.contains("All Variables"),
    "alert=\(transfer.alertTitle): \(transfer.alertMessage)")

// The scope that has content produces a file that actually contains it.
if let written = transfer.exportText(
    profile: profile, dialect: .posixShell, scope: .everything) {
    let assignments = written.text
        .split(separator: "\n")
        .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    checks.expect(
        "the file holds one line per variable",
        assignments.count == 5,
        "found \(assignments.count) assignment lines in:\n\(written.text)")
    checks.expect("PATH is in it", written.text.contains("PATH="))
} else {
    checks.expect("all-variables export produced a file", false)
}

// A normal profile is unaffected: switched-off variables stay out by default.
// The container is bound, not discarded — releasing it destroys the model
// instances it owns, and the next access traps.
let (normalContainer, normal) = snapshotProfile()
_ = normalContainer
normal.name = "dev"
normal.sortedVariables.first?.isEnabled = true
let normalEnabled = DotenvTransfer.variables(of: normal, scope: .enabledOnly)
checks.expect(
    "a normal profile still exports only what it applies",
    normalEnabled.count == 1,
    "carried \(normalEnabled.count)")

print("")
print("passed: \(checks.passed)")
if checks.failed > 0 {
    print("failed: \(checks.failed)")
    exit(1)
}
print("ALL EXPORT CHECKS PASSED")
