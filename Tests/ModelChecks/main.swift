//
//  ModelChecks
//
//  Proves the create / duplicate / import rules against an in-memory
//  SwiftData store — the same `Authoring` code the buttons run — and that a
//  profile turns into the snapshot the engine will actually apply.
//
//  The failure this guards: a variable the user can see in the editor that
//  silently never reaches the shell, or one they switched off that does.
//

import Foundation
import SwiftData

@MainActor
final class Checks {
    var passed = 0
    var failed = 0

    func expect(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition { passed += 1 } else {
            failed += 1
            print("FAIL \(label)")
            let extra = detail()
            if !extra.isEmpty { print("     \(extra)") }
        }
    }
}

@MainActor
func freshStore() -> (ModelContainer, ModelContext) {
    let schema = Schema([Project.self, Profile.self, EnvVariable.self])
    let container = try! ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    return (container, container.mainContext)
}

@MainActor func count<T: PersistentModel>(_ type: T.Type, in context: ModelContext) -> Int {
    (try? context.fetchCount(FetchDescriptor<T>())) ?? -1
}

func entry(_ key: String, _ value: String, line: Int = 1) -> DotenvEntry {
    DotenvEntry(key: EnvKey(key)!, value: EnvValue(value), line: line)
}

let checks = Checks()
// Bound, not discarded: releasing the container destroys the model instances.
let (container, context) = freshStore()
_ = container

// MARK: - Create a project

let project = Authoring.createProject(named: "  payments  ", sortIndex: 0, in: context)
checks.expect("project/name is trimmed", project?.name == "payments")
checks.expect("project/blank name creates nothing",
              Authoring.createProject(named: "   ", sortIndex: 1, in: context) == nil)
try! context.save()
checks.expect("project/only the real one was stored", count(Project.self, in: context) == 1)
checks.expect("project/starts with no profiles", project?.profiles.isEmpty == true)
checks.expect("project/is not the Default", project?.isDefault == false)

// MARK: - Create a profile (an environment)

let dev = Authoring.createProfile(named: " dev ", kind: .dev, in: project!, context: context)
checks.expect("profile/name is trimmed", dev?.name == "dev")
checks.expect("profile/kind is kept", dev?.kind == .dev)
checks.expect("profile/attached to its project", dev?.project === project)
checks.expect("profile/project sees it", project?.profiles.count == 1)
checks.expect("profile/blank name creates nothing",
              Authoring.createProfile(named: "", kind: .prd, in: project!, context: context) == nil)
checks.expect("profile/…and the project is untouched", project?.profiles.count == 1)
let prd = Authoring.createProfile(named: "prd", kind: .prd, in: project!, context: context)
checks.expect("profile/second one lands after the first", prd?.sortIndex == 1)
checks.expect("profile/order follows creation",
              project?.sortedProfiles.map(\.name) == ["dev", "prd"])
checks.expect("profile/a normal profile can be applied", dev?.canBeApplied == true)
try! context.save()
checks.expect("profile/two stored", count(Profile.self, in: context) == 2)

// MARK: - Create variables

let blank = Authoring.addVariable(to: dev!, context: context)
checks.expect("variable/new row is blank and switched on",
              blank.key == "" && blank.value == "" && blank.isEnabled)
checks.expect("variable/blank key is not a valid name", !blank.isKeyValid)
checks.expect("variable/a blank row never reaches the shell",
              SnapshotMapper.snapshot(of: dev!)?.variables.isEmpty == true)

blank.key = "API_URL"
blank.value = "https://api.example.test"
checks.expect("variable/named row is valid", blank.isKeyValid)

let secret = Authoring.addVariable(to: dev!, context: context)
secret.key = "TOKEN"; secret.value = "s3cr3t"; secret.isSecret = true
let off = Authoring.addVariable(to: dev!, context: context)
off.key = "OFF"; off.value = "no"; off.isEnabled = false
let invalid = Authoring.addVariable(to: dev!, context: context)
invalid.key = "1BAD"; invalid.value = "x"
try! context.save()

checks.expect("variable/rows keep insertion order",
              dev?.sortedVariables.map(\.key) == ["API_URL", "TOKEN", "OFF", "1BAD"],
              "\(dev!.sortedVariables.map(\.key))")
checks.expect("variable/editor count includes every row", dev?.variables.count == 4)
checks.expect("variable/enabled count excludes the switched-off one", dev?.enabledVariableCount == 3)

// MARK: - The snapshot: what the engine will actually apply

let snap = SnapshotMapper.snapshot(of: dev!)
checks.expect("snapshot/exists for an attached profile", snap != nil)
checks.expect("snapshot/carries project and profile names", snap?.displayPath == "payments/dev")
checks.expect("snapshot/includes the named variable",
              snap?.variables[EnvKey("API_URL")!]?.rawValue == "https://api.example.test")
checks.expect("snapshot/secret is exported in plaintext — hiding is presentation only",
              snap?.variables[EnvKey("TOKEN")!]?.rawValue == "s3cr3t")
checks.expect("snapshot/switched-off variable is left out",
              snap?.variables.contains(EnvKey("OFF")!) == false)
checks.expect("snapshot/invalid name is left out", snap?.variables.count == 2,
              "keys=\(snap?.variables.keys.map(\.rawValue) ?? [])")

let orphan = Profile(name: "loose", kind: .custom)
context.insert(orphan)
checks.expect("snapshot/a profile without a project has none", SnapshotMapper.snapshot(of: orphan) == nil)
context.delete(orphan)

// MARK: - Duplicate

let copy = Authoring.duplicate(dev!, context: context)
try! context.save()
checks.expect("duplicate/name says so", copy.name == "dev copy")
checks.expect("duplicate/kind is kept", copy.kind == .dev)
checks.expect("duplicate/same project", copy.project === project)
checks.expect("duplicate/every variable is copied", copy.variables.count == 4)
checks.expect("duplicate/values and flags travel",
              copy.sortedVariables.map { "\($0.key)=\($0.value):\($0.isEnabled):\($0.isSecret)" }
              == dev!.sortedVariables.map { "\($0.key)=\($0.value):\($0.isEnabled):\($0.isSecret)" })
checks.expect("duplicate/copies are independent objects",
              Set(copy.variables.map(\.id)).isDisjoint(with: dev!.variables.map(\.id)))
copy.sortedVariables.first?.value = "changed in the copy"
checks.expect("duplicate/editing the copy leaves the original alone",
              dev!.sortedVariables.first?.value == "https://api.example.test")

let defaultProject = Project(name: "Default", isDefault: true, sortIndex: -1)
context.insert(defaultProject)
let machine = Profile(name: "Default", kind: .systemDefault, isDefault: true)
machine.project = defaultProject
context.insert(machine)
let seeded = EnvVariable(key: "PATH", value: "/usr/bin", isEnabled: false, origin: .imported, bucket: .pathLike)
seeded.profile = machine
context.insert(seeded)
try! context.save()
checks.expect("default/the machine snapshot cannot be applied", !machine.canBeApplied)
let usable = Authoring.duplicate(machine, context: context)
checks.expect("default/its copy becomes a custom profile", usable.kind == .custom)
checks.expect("default/…which can be applied", usable.canBeApplied)
checks.expect("default/copied variables become authored, not imported",
              usable.variables.first?.origin == .authored)
checks.expect("default/copied variables stay switched off as they were",
              usable.variables.first?.isEnabled == false)

// MARK: - Import (merge)

Authoring.merge(
    [entry("API_URL", "https://staging.example.test"), entry("NEW_ONE", "1"), entry("NEW_TWO", "2")],
    into: dev!, context: context)
try! context.save()
checks.expect("import/existing key is updated in place",
              dev!.sortedVariables.first { $0.key == "API_URL" }?.value == "https://staging.example.test")
checks.expect("import/existing row keeps its identity and origin",
              dev!.sortedVariables.first { $0.key == "API_URL" }?.id == blank.id
              && blank.origin == .authored)
checks.expect("import/new keys are created", dev!.variables.count == 6, "count=\(dev!.variables.count)")
checks.expect("import/new rows are marked imported",
              dev!.sortedVariables.filter { $0.origin == .imported }.map(\.key).sorted() == ["NEW_ONE", "NEW_TWO"])
checks.expect("import/new rows land at the end",
              dev!.sortedVariables.suffix(2).map(\.key) == ["NEW_ONE", "NEW_TWO"])
Authoring.merge([entry("NEW_ONE", "again")], into: dev!, context: context)
checks.expect("import/importing twice does not duplicate a key", dev!.variables.count == 6)
checks.expect("import/duplicate entry in one file: last wins",
              { Authoring.merge([entry("DUP", "a"), entry("DUP", "b")], into: dev!, context: context)
                return dev!.sortedVariables.first { $0.key == "DUP" }?.value == "b"
                    && dev!.variables.filter { $0.key == "DUP" }.count == 1 }())

// MARK: - Delete cascades

let variablesBefore = count(EnvVariable.self, in: context)
context.delete(prd!)
try! context.save()
checks.expect("delete/profile removal leaves the project", count(Project.self, in: context) == 2)
checks.expect("delete/project no longer lists it", project?.profiles.contains { $0.name == "prd" } == false)

let devVariableCount = dev!.variables.count
context.delete(dev!)
try! context.save()
checks.expect("delete/a profile takes its variables with it",
              count(EnvVariable.self, in: context) == variablesBefore - devVariableCount,
              "before=\(variablesBefore) removed=\(devVariableCount) now=\(count(EnvVariable.self, in: context))")

context.delete(project!)
try! context.save()
checks.expect("delete/a project takes its profiles with it",
              count(Profile.self, in: context) == 2, "profiles left=\(count(Profile.self, in: context))")
checks.expect("delete/…and their variables",
              count(EnvVariable.self, in: context) == 2, "variables left=\(count(EnvVariable.self, in: context))")

print("")
print("passed: \(checks.passed)")
if checks.failed > 0 {
    print("failed: \(checks.failed)")
    exit(1)
}
print("ALL MODEL CHECKS PASSED")
