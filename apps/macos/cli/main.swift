//
//  main.swift — the `hyperenv` command
//
//  The one door the editor plugins use. It opens the SAME SwiftData store and
//  drives the SAME ApplyEngine as the app, so there is one engine, one journal
//  and one writer to ~/.zprofile no matter which window pressed the button.
//
//  Grammar:  hyperenv [--json] <noun> [verb] [options]
//  Output:   --json wraps every result as {"ok":true,"data":…} or
//            {"ok":false,"error":"…"}; exit status 0 or 1 either way.
//
//  Compiled with Core, Engine and Models by Scripts/build-cli.sh. No
//  dependencies beyond the SDK, like the rest of the repository.
//

import Foundation
import SwiftData

// MARK: - Arguments

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let word = raw[index]
            if word.hasPrefix("--") {
                let name = String(word.dropFirst(2))
                if let equals = name.firstIndex(of: "=") {
                    options[String(name[..<equals])] = String(name[name.index(after: equals)...])
                } else if index + 1 < raw.count, !raw[index + 1].hasPrefix("--"),
                          Self.valued.contains(name) {
                    options[name] = raw[index + 1]
                    index += 1
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(word)
            }
            index += 1
        }
    }

    /// Options that take a value. Anything else after `--` is a flag, so
    /// `--secret KEY=VALUE` does not swallow the pair.
    private static let valued: Set<String> = ["project", "profile", "name", "kind", "note", "store"]

    func option(_ name: String) -> String? { options[name] }
    func has(_ flag: String) -> Bool { flags.contains(flag) }
}

// MARK: - Failure

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

// MARK: - Output shapes

struct ProfileOut: Codable {
    let id: UUID
    let name: String
    let kind: String
    let isDefault: Bool
    let canBeApplied: Bool
    let isApplied: Bool
    let variableCount: Int
    let enabledCount: Int
    let sortIndex: Int
}

struct ProjectOut: Codable {
    let id: UUID
    let name: String
    let isDefault: Bool
    let folderPath: String?
    let sortIndex: Int
    let profiles: [ProfileOut]
}

struct VariableOut: Codable {
    let id: UUID
    let key: String
    let value: String
    let isEnabled: Bool
    let isSecret: Bool
    let note: String?
    let origin: String
    let isValid: Bool
    let sortIndex: Int
}

struct AppliedOut: Codable {
    let projectId: UUID
    let projectName: String
    let profileId: UUID
    let profileName: String
    let appliedAt: Date
    let exportedKeys: [String]
}

struct StatusOut: Codable {
    let version: String
    let applied: AppliedOut?
    let hook: String
    let hookDetail: String?
    let drift: [String]
    let pendingRecoveries: Int
    let reloadCommand: String
    let undoCommand: String
    let sessionScript: String
    let dotfile: String
    let store: String
}

struct ApplyOut: Codable {
    let applied: AppliedOut
    let exported: Int
    let captured: Int
    let restored: Int
    let reloadCommand: String
}

struct UnapplyOut: Codable {
    let restored: Int
    let undoCommand: String
}

struct DeletedOut: Codable { let deleted: String }
struct HookOut: Codable { let hook: String; let dotfile: String }
struct VersionOut: Codable { let version: String }

struct Envelope<T: Codable>: Codable {
    let ok: Bool
    let data: T?
    let error: String?
}

// MARK: - Store

@MainActor
enum Store {
    /// The app's store, unless `HYPERENV_STORE` or `--store` points elsewhere —
    /// which only the checks do, so they never touch the real one.
    static func open(override: String?) throws -> (ModelContainer, ModelContext, String) {
        let schema = Schema([Project.self, Profile.self, EnvVariable.self])
        let configuration: ModelConfiguration
        if let override = override ?? ProcessInfo.processInfo.environment["HYPERENV_STORE"] {
            let url = URL(fileURLWithPath: override)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: url)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        }
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, container.mainContext, configuration.url.path(percentEncoded: false))
    }

    static func projects(in context: ModelContext) throws -> [Project] {
        try context.fetch(FetchDescriptor<Project>())
            .sorted { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) }
    }

    /// A UUID or an exact name. Ambiguity is an error, never a guess.
    static func project(_ reference: String?, in context: ModelContext) throws -> Project {
        guard let reference, !reference.isEmpty else { throw CLIError("--project is required") }
        let all = try projects(in: context)
        if let id = UUID(uuidString: reference), let match = all.first(where: { $0.id == id }) {
            return match
        }
        let byName = all.filter { $0.name == reference }
        switch byName.count {
        case 0: throw CLIError("no project named \"\(reference)\"")
        case 1: return byName[0]
        default: throw CLIError("\(byName.count) projects are named \"\(reference)\" — use the id")
        }
    }

    static func profile(_ reference: String?, in project: Project) throws -> Profile {
        guard let reference, !reference.isEmpty else { throw CLIError("--profile is required") }
        if let id = UUID(uuidString: reference), let match = project.profiles.first(where: { $0.id == id }) {
            return match
        }
        let byName = project.profiles.filter { $0.name == reference }
        switch byName.count {
        case 0: throw CLIError("no profile named \"\(reference)\" in \(project.name)")
        case 1: return byName[0]
        default: throw CLIError("\(byName.count) profiles are named \"\(reference)\" — use the id")
        }
    }

    static func variable(_ key: String, in profile: Profile) throws -> EnvVariable {
        guard let match = profile.variables.first(where: { $0.key == key }) else {
            throw CLIError("no variable \(key) in \(profile.project?.name ?? "?")/\(profile.name)")
        }
        return match
    }
}

// MARK: - Mapping

@MainActor
func out(_ profile: Profile, appliedID: UUID?) -> ProfileOut {
    ProfileOut(
        id: profile.id, name: profile.name, kind: profile.kind.rawValue,
        isDefault: profile.isDefault, canBeApplied: profile.canBeApplied,
        isApplied: profile.id == appliedID,
        variableCount: profile.variables.count, enabledCount: profile.enabledVariableCount,
        sortIndex: profile.sortIndex)
}

@MainActor
func out(_ project: Project, appliedID: UUID?) -> ProjectOut {
    ProjectOut(
        id: project.id, name: project.name, isDefault: project.isDefault,
        folderPath: project.folderPath, sortIndex: project.sortIndex,
        profiles: project.sortedProfiles.map { out($0, appliedID: appliedID) })
}

@MainActor
func out(_ variable: EnvVariable) -> VariableOut {
    VariableOut(
        id: variable.id, key: variable.key, value: variable.value,
        isEnabled: variable.isEnabled, isSecret: variable.isSecret, note: variable.note,
        origin: variable.origin.rawValue, isValid: variable.isKeyValid, sortIndex: variable.sortIndex)
}

func out(_ transaction: ApplyTransaction) -> AppliedOut {
    AppliedOut(
        projectId: transaction.projectID, projectName: transaction.projectName,
        profileId: transaction.profileID, profileName: transaction.profileName,
        appliedAt: transaction.timestamp, exportedKeys: transaction.exports.keys.map(\.rawValue))
}

func describe(_ drift: DriftKind) -> String {
    if case .semantic(let details) = drift {
        return "semantic: " + details.keys.map(\.rawValue).sorted().joined(separator: ", ")
    }
    return String(describing: drift)
}

func describe(_ status: HookStatus) -> (String, String?) {
    switch status {
    case .installed: ("installed", nil)
    case .notInstalled: ("notInstalled", nil)
    case .malformed(let detail): ("malformed", detail)
    }
}

// MARK: - Printing

let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}()

func emit<T: Codable>(_ value: T, json: Bool, text: () -> String) {
    if json {
        let data = try! jsonEncoder.encode(Envelope(ok: true, data: value, error: nil))
        print(String(decoding: data, as: UTF8.self))
    } else {
        print(text())
    }
}

func fail(_ message: String, json: Bool) -> Never {
    if json {
        let data = try! jsonEncoder.encode(Envelope<VersionOut>(ok: false, data: nil, error: message))
        print(String(decoding: data, as: UTF8.self))
    } else {
        FileHandle.standardError.write(Data("hyperenv: \(message)\n".utf8))
    }
    exit(1)
}

let usage = """
hyperenv — the command behind the HyperEnv app and its editor plugins

  hyperenv status                                    what is applied, hook, drift
  hyperenv projects                                  every project with its profiles
  hyperenv project create <name>
  hyperenv project delete --project <id|name>
  hyperenv profile create --project <p> --name <n> [--kind dev|hml|prd|custom]
  hyperenv profile duplicate --project <p> --profile <id|name>
  hyperenv profile delete --project <p> --profile <id|name>
  hyperenv vars --project <p> --profile <id|name>
  hyperenv var set --project <p> --profile <f> KEY=VALUE [--secret] [--disabled] [--note <text>]
  hyperenv var enable|disable|delete --project <p> --profile <f> KEY
  hyperenv apply --project <p> --profile <f>
  hyperenv unapply
  hyperenv hook install|remove
  hyperenv version

  --json     machine-readable output, always on stdout
  --store    path to a store file (checks only; the default is the app's)
"""

// MARK: - Main

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
let json = arguments.has("json")
let words = arguments.positional

@MainActor
func run() async throws {
    guard let noun = words.first else { print(usage); return }
    let verb = words.count > 1 ? words[1] : nil

    if noun == "version" || arguments.has("version") {
        emit(VersionOut(version: CLIVersion.string), json: json) { CLIVersion.string }
        return
    }
    if noun == "help" || arguments.has("help") { print(usage); return }

    let engine = ApplyEngine()
    let (container, context, storePath) = try Store.open(override: arguments.option("store"))
    _ = container
    let appliedID = try await engine.current()?.profileID

    switch (noun, verb) {

    case ("status", nil):
        let applied = try await engine.current()
        let (hook, detail) = describe(await engine.hookStatus())
        let drift = (try? await engine.detectDrift()) ?? []
        let status = StatusOut(
            version: CLIVersion.string,
            applied: applied.map(out),
            hook: hook, hookDetail: detail,
            drift: drift.map(describe),
            pendingRecoveries: (try? await engine.pendingRecoveries().count) ?? 0,
            reloadCommand: await engine.reloadCommand,
            undoCommand: await engine.undoCommand,
            sessionScript: Paths.displayPath(Paths.sessionScript),
            dotfile: Paths.displayPath(Paths.zprofile),
            store: storePath)
        emit(status, json: json) {
            var lines = ["applied:  " + (applied.map { "\($0.displayPath) (\($0.exports.count) variables)" } ?? "nothing")]
            lines.append("hook:     \(hook)" + (detail.map { " — \($0)" } ?? ""))
            lines.append("drift:    " + (drift.isEmpty ? "none" : drift.map(describe).joined(separator: "; ")))
            if applied != nil { lines.append("reload:   \(status.reloadCommand)") }
            return lines.joined(separator: "\n")
        }

    case ("projects", nil):
        let projects = try Store.projects(in: context).map { out($0, appliedID: appliedID) }
        emit(projects, json: json) {
            projects.flatMap { project in
                ["\(project.name)  (\(project.id))"] + project.profiles.map {
                    "  \($0.isApplied ? "●" : "○") \($0.name) [\($0.kind)]  \($0.enabledCount)/\($0.variableCount) on  (\($0.id))"
                }
            }.joined(separator: "\n")
        }

    case ("project", "create"):
        guard words.count > 2 else { throw CLIError("project create needs a name") }
        let count = try Store.projects(in: context).count
        guard let project = Authoring.createProject(named: words[2], sortIndex: count, in: context) else {
            throw CLIError("a project needs a name")
        }
        try context.save()
        emit(out(project, appliedID: appliedID), json: json) { "created project \(project.name) (\(project.id))" }

    case ("project", "delete"):
        let project = try Store.project(arguments.option("project"), in: context)
        guard !project.isDefault else { throw CLIError("the Default project holds the machine snapshot and cannot be deleted") }
        if let appliedID, project.profiles.contains(where: { $0.id == appliedID }) {
            throw CLIError("\(project.name) has the applied profile — un-apply first")
        }
        let name = project.name
        context.delete(project)
        try context.save()
        emit(DeletedOut(deleted: name), json: json) { "deleted project \(name)" }

    case ("profile", "create"):
        let project = try Store.project(arguments.option("project"), in: context)
        let kindRaw = arguments.option("kind") ?? "custom"
        guard let kind = ProfileKind(rawValue: kindRaw), kind != .systemDefault else {
            throw CLIError("--kind must be dev, hml, prd or custom")
        }
        guard let profile = Authoring.createProfile(
            named: arguments.option("name") ?? "", kind: kind, in: project, context: context) else {
            throw CLIError("a profile needs --name")
        }
        try context.save()
        emit(out(profile, appliedID: appliedID), json: json) { "created \(project.name)/\(profile.name) (\(profile.id))" }

    case ("profile", "duplicate"):
        let project = try Store.project(arguments.option("project"), in: context)
        let source = try Store.profile(arguments.option("profile"), in: project)
        let copy = Authoring.duplicate(source, context: context)
        try context.save()
        emit(out(copy, appliedID: appliedID), json: json) { "created \(project.name)/\(copy.name) (\(copy.id))" }

    case ("profile", "delete"):
        let project = try Store.project(arguments.option("project"), in: context)
        let profile = try Store.profile(arguments.option("profile"), in: project)
        guard !profile.isDefault else { throw CLIError("the Default profile is the machine snapshot and cannot be deleted") }
        guard profile.id != appliedID else { throw CLIError("\(profile.name) is applied — un-apply first") }
        let name = "\(project.name)/\(profile.name)"
        context.delete(profile)
        try context.save()
        emit(DeletedOut(deleted: name), json: json) { "deleted \(name)" }

    case ("vars", nil):
        let project = try Store.project(arguments.option("project"), in: context)
        let profile = try Store.profile(arguments.option("profile"), in: project)
        let variables = profile.sortedVariables.map { out($0) }
        emit(variables, json: json) {
            variables.map { "\($0.isEnabled ? "on " : "off") \($0.key)=\($0.isSecret ? "••••••" : $0.value)" }
                .joined(separator: "\n")
        }

    case ("var", "set"):
        let project = try Store.project(arguments.option("project"), in: context)
        let profile = try Store.profile(arguments.option("profile"), in: project)
        guard words.count > 2, let equals = words[2].firstIndex(of: "=") else {
            throw CLIError("var set needs KEY=VALUE")
        }
        let key = String(words[2][..<equals])
        let value = String(words[2][words[2].index(after: equals)...])
        guard EnvKey.isValid(key) else { throw CLIError("\"\(key)\" is not a valid variable name") }

        let variable: EnvVariable
        if let existing = profile.variables.first(where: { $0.key == key }) {
            variable = existing
        } else {
            variable = Authoring.addVariable(to: profile, context: context)
            variable.key = key
        }
        variable.value = value
        if arguments.has("secret") { variable.isSecret = true }
        if arguments.has("disabled") { variable.isEnabled = false }
        if arguments.has("enabled") { variable.isEnabled = true }
        if let note = arguments.option("note") { variable.note = note }
        try context.save()
        emit(out(variable), json: json) { "set \(key) in \(project.name)/\(profile.name)" }

    case ("var", "enable"), ("var", "disable"):
        let project = try Store.project(arguments.option("project"), in: context)
        let profile = try Store.profile(arguments.option("profile"), in: project)
        guard words.count > 2 else { throw CLIError("var \(verb!) needs KEY") }
        let variable = try Store.variable(words[2], in: profile)
        variable.isEnabled = verb == "enable"
        try context.save()
        emit(out(variable), json: json) { "\(verb!)d \(variable.key)" }

    case ("var", "delete"):
        let project = try Store.project(arguments.option("project"), in: context)
        let profile = try Store.profile(arguments.option("profile"), in: project)
        guard words.count > 2 else { throw CLIError("var delete needs KEY") }
        let variable = try Store.variable(words[2], in: profile)
        let key = variable.key
        context.delete(variable)
        try context.save()
        emit(DeletedOut(deleted: key), json: json) { "deleted \(key)" }

    case ("apply", nil):
        let project = try Store.project(arguments.option("project"), in: context)
        let profile = try Store.profile(arguments.option("profile"), in: project)
        guard profile.canBeApplied else {
            throw CLIError("the Default profile is a snapshot of the machine and cannot be applied — duplicate it first")
        }
        guard let snapshot = SnapshotMapper.snapshot(of: profile) else {
            throw CLIError("profile is not attached to a project")
        }
        let outcome = try await engine.apply(snapshot)
        let result = ApplyOut(
            applied: out(outcome.transaction),
            exported: outcome.plan.exports.count,
            captured: outcome.plan.captures.count,
            restored: outcome.plan.restores.count,
            reloadCommand: outcome.reloadCommand)
        emit(result, json: json) {
            "applied \(snapshot.displayPath): \(result.exported) variables exported\nnew terminals inherit it; for this one:  \(result.reloadCommand)"
        }

    case ("unapply", nil):
        let plan = try await engine.unapply()
        let result = UnapplyOut(restored: plan.restores.count, undoCommand: await engine.undoCommand)
        emit(result, json: json) {
            plan.isNoOp ? "nothing was applied" : "reverted \(result.restored) variables\nfor this terminal:  \(result.undoCommand)"
        }

    case ("hook", "install"), ("hook", "remove"):
        if verb == "install" { try await engine.installHook() } else { try await engine.removeHook() }
        let (hook, _) = describe(await engine.hookStatus())
        emit(HookOut(hook: hook, dotfile: Paths.displayPath(Paths.zprofile)), json: json) {
            "hook \(hook) in \(Paths.displayPath(Paths.zprofile))"
        }

    default:
        throw CLIError("unknown command \"\(([noun] + (verb.map { [$0] } ?? [])).joined(separator: " "))\"\n\n\(usage)")
    }
}

do {
    try await run()
} catch let error as CLIError {
    fail(error.description, json: json)
} catch let error as HyperEnvError {
    fail(error.localizedDescription, json: json)
} catch {
    fail("\(error)", json: json)
}
