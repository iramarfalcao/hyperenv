//
//  EngineChecks
//
//  Drives the real ApplyEngine through a whole life: apply, apply again,
//  un-apply, remove the hook — against an in-memory filesystem, a scripted
//  probe and a temporary lock file. Nothing under $HOME is read or written.
//
//  The Core suite proves the strings are right and the shell suite proves a
//  real zsh honours them. This one proves the *engine* keeps its promises in
//  between: the journal is written before the dotfile, the baseline is
//  captured once and never re-measured, the backup is taken once, the hook
//  is installed once, and un-apply leaves the machine recoverable.
//

import Foundation

// MARK: - Harness

var failures: [String] = []
var passed = 0

@MainActor func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { passed += 1 } else {
        let extra = detail()
        failures.append("FAIL \(label)" + (extra.isEmpty ? "" : "\n     \(extra)"))
    }
}

// MARK: - Fakes

/// Every write the engine makes, kept in memory and keyed by path.
nonisolated final class InMemoryFileSystem: FileSystemGateway, @unchecked Sendable {
    struct Entry { var data: Data; var permissions: Int16? }

    private let lock = NSLock()
    private var files: [String: Entry] = [:]
    private var directories: Set<String> = []
    private var writeLog: [String] = []

    /// Trailing slashes stripped, so a directory URL and the parent of a file
    /// inside it compare equal.
    private func key(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    func exists(_ url: URL) -> Bool {
        lock.withLock { files[key(url)] != nil || directories.contains(key(url)) }
    }
    func readData(_ url: URL) throws -> Data {
        try lock.withLock {
            guard let entry = files[key(url)] else { throw CocoaError(.fileReadNoSuchFile) }
            return entry.data
        }
    }
    func readText(_ url: URL) throws -> String {
        guard let text = String(data: try readData(url), encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }
    func write(_ data: Data, to url: URL, permissions: Int16?) throws {
        lock.withLock {
            files[key(url)] = Entry(data: data, permissions: permissions)
            directories.insert(key(url.deletingLastPathComponent()))
            writeLog.append(key(url))
        }
    }
    func createDirectory(_ url: URL) throws { lock.withLock { _ = directories.insert(key(url)) } }
    func remove(_ url: URL) throws { lock.withLock { _ = files.removeValue(forKey: key(url)) } }
    func contentsOfDirectory(_ url: URL) throws -> [URL] {
        let parent = key(url)
        return lock.withLock {
            files.keys
                .filter { key(URL(fileURLWithPath: $0).deletingLastPathComponent()) == parent }
                .sorted()
                .map { URL(fileURLWithPath: $0) }
        }
    }
    func resolvingSymlink(_ url: URL) throws -> URL { url }
    func modificationDate(_ url: URL) -> Date? { nil }

    // Inspection
    func text(at url: URL) -> String? { try? readText(url) }
    func permissions(at url: URL) -> Int16? { lock.withLock { files[key(url)]?.permissions } }
    func writeCount(of url: URL) -> Int { lock.withLock { writeLog.filter { $0 == key(url) }.count } }
    func names(in url: URL) -> [String] { (try? contentsOfDirectory(url))?.map(\.lastPathComponent) ?? [] }
}

/// Reports whatever the test says the shell reports. Mutable so a later apply
/// can see a different machine — which is exactly what the baseline rule has
/// to survive.
nonisolated final class ScriptedProbe: EnvironmentProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var observed: EnvSet
    init(_ observed: EnvSet) { self.observed = observed }
    func set(_ observed: EnvSet) { lock.withLock { self.observed = observed } }
    func probe(bypassHyperEnv: Bool) async throws -> ProbeResult {
        lock.withLock { ProbeResult(observed: observed, base: EnvSet(), interactiveOnly: []) }
    }
}

// MARK: - Fixtures

func envSet(_ pairs: [(String, String)]) -> EnvSet {
    var set = EnvSet()
    for (k, v) in pairs { set[EnvKey(k)!] = EnvValue(v) }
    return set
}

func snapshot(_ project: String, _ profile: String, _ pairs: [(String, String)]) -> ProfileSnapshot {
    ProfileSnapshot(
        profileID: UUID(), profileName: profile, kind: .dev,
        projectID: UUID(), projectName: project, projectFolderPath: nil,
        variables: envSet(pairs))
}

let scratch = FileManager.default.temporaryDirectory
    .appending(path: "hyperenv-enginechecks-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let lockURL = scratch.appending(path: "lock")

let userZprofile = "export PRE='original'\nexport UNTOUCHED='leave me alone'\n"
let machine = envSet([("PRE", "original"), ("UNTOUCHED", "leave me alone")])

@MainActor
func freshEngine(zprofile: String? = userZprofile)
    -> (fs: InMemoryFileSystem, probe: ScriptedProbe, engine: ApplyEngine)
{
    let fs = InMemoryFileSystem()
    if let zprofile { try! fs.write(zprofile, to: Paths.zprofile, permissions: nil) }
    let probe = ScriptedProbe(machine)
    let engine = ApplyEngine(fileSystem: fs, probe: probe, lockFile: lockURL)
    return (fs, probe, engine)
}

// MARK: - 0. Paths: the hook must point where the file is

// Foundation returns "/Users/me/" for an existing home directory. The 1.0.x
// hook was rendered from that and pointed at "${HOME}.config/…" — a path that
// does not exist, so every new shell silently inherited nothing.
check("paths/home has no trailing slash in the shell form",
      Paths.shellRelative(Paths.sessionScript) == "${HOME}/.config/hyperenv/session.zsh",
      Paths.shellRelative(Paths.sessionScript))
check("paths/display form keeps the slash", Paths.displayPath(Paths.zprofile) == "~/.zprofile",
      Paths.displayPath(Paths.zprofile))
check("paths/the home directory itself displays as ~", Paths.displayPath(Paths.home) == "~")
// "/Users/me-other/x" shares every character of "/Users/me" and must not be
// mistaken for something inside it.
let homeNoSlash: String = {
    var h = Paths.home.path(percentEncoded: false)
    while h.count > 1, h.hasSuffix("/") { h.removeLast() }
    return h
}()
check("paths/a sibling of home is not rewritten",
      Paths.shellRelative(URL(fileURLWithPath: homeNoSlash + "-other/x")) == homeNoSlash + "-other/x",
      Paths.shellRelative(URL(fileURLWithPath: homeNoSlash + "-other/x")))
check("paths/the rendered hook points at a real path",
      SessionScriptRenderer.hookBody(sessionPath: Paths.shellRelative(Paths.sessionScript))
        .joined().contains("\"${HOME}/.config/hyperenv/session.zsh\""))

// MARK: - 1. Nothing applied yet

do {
    let (fs, _, engine) = freshEngine()
    check("fresh/hook is not installed", await engine.hookStatus() == .notInstalled)
    check("fresh/no current transaction", try await engine.current() == nil)

    let plan = try await engine.unapply()
    check("fresh/un-apply with nothing applied is a no-op", plan.isNoOp)
    check("fresh/…and writes nothing", fs.writeCount(of: Paths.sessionScript) == 0
          && fs.writeCount(of: Paths.zprofile) == 1)
    check("fresh/no orphaned transactions", try await engine.pendingRecoveries().isEmpty)
}

// MARK: - 2. First apply

let (fs, probe, engine) = freshEngine()
let dev = snapshot("payments", "dev", [("PRE", "applied"), ("NEW", "hello world")])
let first = try await engine.apply(dev)

check("apply/transaction is committed", first.transaction.state == .applied)
check("apply/current journal names the profile",
      try await engine.current()?.displayPath == "payments/dev")
check("apply/session.zsh exists", fs.exists(Paths.sessionScript))
check("apply/session.zsh is 0600", fs.permissions(at: Paths.sessionScript) == 0o600)
check("apply/unsession.zsh is 0600", fs.permissions(at: Paths.unsessionScript) == 0o600)
check("apply/session exports the new variable",
      fs.text(at: Paths.sessionScript)?.contains("NEW=") == true)
check("apply/session exports the override",
      fs.text(at: Paths.sessionScript)?.contains("applied") == true)
check("apply/hook is installed", await engine.hookStatus() == .installed)
check("apply/user's lines survive above the block",
      fs.text(at: Paths.zprofile)?.hasPrefix(userZprofile) == true)
check("apply/the block written to the dotfile points at ${HOME}/.config",
      fs.text(at: Paths.zprofile)?.contains("${HOME}/.config/hyperenv/session.zsh") == true,
      fs.text(at: Paths.zprofile) ?? "")
// One write from the fixture, one from installing the hook.
check("apply/installing the hook wrote the dotfile once", fs.writeCount(of: Paths.zprofile) == 2,
      "writes=\(fs.writeCount(of: Paths.zprofile))")
let dotfileWritesAfterFirstApply = fs.writeCount(of: Paths.zprofile)

let backups = fs.names(in: Paths.backupsDirectory)
check("apply/exactly one backup", backups.count == 1, "backups=\(backups)")
check("apply/backup is the pristine dotfile",
      backups.first.flatMap { fs.text(at: Paths.backupsDirectory.appending(path: $0)) } == userZprofile)
check("apply/backup is private", backups.first.flatMap {
    fs.permissions(at: Paths.backupsDirectory.appending(path: $0)) } == 0o600)

let history1 = fs.names(in: Paths.historyDirectory)
check("apply/one history record", history1.filter { $0.hasSuffix(".json") && !$0.hasSuffix(".pending.json") }.count == 1)
check("apply/no pending record left behind", !history1.contains { $0.hasSuffix(".pending.json") })
check("apply/no orphan reported", try await engine.pendingRecoveries().isEmpty)

let managed1 = first.transaction.managed
check("apply/baseline of an overridden key is its original value",
      managed1.baseline(for: EnvKey("PRE")!) == .present(EnvValue("original")))
check("apply/baseline of a brand-new key is absent",
      managed1.baseline(for: EnvKey("NEW")!) == .absent)
check("apply/unrelated key is not managed", !managed1.isManaged(EnvKey("UNTOUCHED")!))
check("apply/session hash matches the file",
      fs.text(at: Paths.sessionScript).map { fs.sha256($0) } == first.transaction.sessionScriptHash)
check("apply/marker hash recorded", !first.transaction.markerBlockHash.isEmpty)
check("apply/reload command points at the session file",
      first.reloadCommand.hasSuffix("session.zsh"))

// MARK: - 3. Second apply: the baseline must not move, the dotfile must not be touched

// The machine now *looks* different with HyperEnv bypassed — as if the user
// edited their own dotfile. A key we already own must keep its first baseline.
probe.set(envSet([("PRE", "drifted"), ("UNTOUCHED", "leave me alone")]))
let prd = snapshot("payments", "prd", [("PRE", "prd value"), ("OTHER", "x")])
let second = try await engine.apply(prd)

check("reapply/dotfile is not written again", fs.writeCount(of: Paths.zprofile) == dotfileWritesAfterFirstApply)
check("reapply/still exactly one backup", fs.names(in: Paths.backupsDirectory).count == 1)
check("reapply/managed key keeps its FIRST baseline",
      second.transaction.managed.baseline(for: EnvKey("PRE")!) == .present(EnvValue("original")))
check("reapply/dropped key is released", !second.transaction.managed.isManaged(EnvKey("NEW")!))
check("reapply/new key is captured as absent",
      second.transaction.managed.baseline(for: EnvKey("OTHER")!) == .absent)
check("reapply/session no longer exports the dropped key",
      fs.text(at: Paths.sessionScript)?.contains("NEW=") == false)
check("reapply/current journal moved to the new profile",
      try await engine.current()?.profileName == "prd")
check("reapply/inverse hands the dropped key back",
      fs.text(at: Paths.unsessionScript)?.contains("NEW") == true)
check("reapply/two history records",
      fs.names(in: Paths.historyDirectory).filter { !$0.hasSuffix(".pending.json") }.count == 2)

// MARK: - 4. Drift

try fs.write("# hand edited\n", to: Paths.sessionScript, permissions: 0o600)
probe.set(envSet([("PRE", "someone else"), ("UNTOUCHED", "leave me alone")]))
let drift = try await engine.detectDrift()
check("drift/hand-edited session is detected",
      drift.contains { if case .managedFileEdited = $0 { true } else { false } })
check("drift/hook still present is not reported",
      !drift.contains { if case .markerBlockMissing = $0 { true } else { false } })
check("drift/shell disagreeing with our exports is detected",
      drift.contains { if case .semantic = $0 { true } else { false } })

// MARK: - 5. Un-apply

let undo = try await engine.unapply()
check("unapply/plan restores every managed key", undo.restores.count == 2, "restores=\(undo.restores.keys.map(\.rawValue))")
check("unapply/current journal is cleared", try await engine.current() == nil)
check("unapply/session file still exists (empty, not deleted)", fs.exists(Paths.sessionScript))
check("unapply/session exports nothing",
      fs.text(at: Paths.sessionScript)?.contains("export ") == false)
check("unapply/inverse restores the ORIGINAL, not the intermediate",
      fs.text(at: Paths.unsessionScript)?.contains("original") == true
      && fs.text(at: Paths.unsessionScript)?.contains("prd value") == false)
check("unapply/history closes the transaction as unapplied",
      fs.text(at: Paths.historyDirectory.appending(path: "\(second.transaction.id.uuidString).json"))?
        .contains("unapplied") == true)
check("unapply/no orphan reported", try await engine.pendingRecoveries().isEmpty)
check("unapply/hook stays installed so re-applying is instant",
      await engine.hookStatus() == .installed)
check("unapply/drift is silent when nothing is applied", try await engine.detectDrift().isEmpty)

// MARK: - 6. Remove the hook

try await engine.removeHook()
check("removeHook/dotfile is byte-identical to the original",
      fs.text(at: Paths.zprofile) == userZprofile)
check("removeHook/status is not installed", await engine.hookStatus() == .notInstalled)
check("removeHook/backup is kept, never pruned", fs.names(in: Paths.backupsDirectory).count == 1)

// MARK: - 7. A dotfile that never existed

do {
    let (fs, _, engine) = freshEngine(zprofile: nil)
    _ = try await engine.apply(dev)
    check("noDotfile/hook is created", await engine.hookStatus() == .installed)
    check("noDotfile/nothing to back up, so no backup", fs.names(in: Paths.backupsDirectory).isEmpty)
    try await engine.removeHook()
    check("noDotfile/removing leaves an empty file, not garbage",
          fs.text(at: Paths.zprofile)?.trimmingCharacters(in: .whitespacesAndNewlines) == "")
}

// MARK: - 8. A malformed hook is refused, and the failure is recoverable

do {
    let (fs, _, engine) = freshEngine(zprofile: "\(BlockMarkers.v1.begin)\nexport X=1\n")
    if case .malformed = await engine.hookStatus() { passed += 1 } else {
        failures.append("FAIL malformed/status reports the broken block")
    }
    var threw = false
    do { _ = try await engine.apply(dev) } catch { threw = true }
    check("malformed/apply refuses rather than guessing", threw)
    check("malformed/no transaction is left as current", try await engine.current() == nil)
    check("malformed/the intent is kept as an orphan for recovery",
          try await engine.pendingRecoveries().count == 1)
    check("malformed/dotfile was not rewritten", fs.writeCount(of: Paths.zprofile) == 1)
}

// MARK: - 9. The lock

do {
    let (_, _, engine) = freshEngine()
    let held = try FileLock(path: lockURL)
    var lockError = false
    do { _ = try await engine.apply(dev) } catch HyperEnvError.lockUnavailable { lockError = true } catch {}
    held.release()
    check("lock/a second writer is refused while the lock is held", lockError)
    check("lock/…and nothing was applied", try await engine.current() == nil)
    _ = try await engine.apply(dev)
    check("lock/works again once released", try await engine.current() != nil)
}

// MARK: - Report

print("")
for failure in failures { print(failure) }
print("passed: \(passed)")
if !failures.isEmpty {
    print("failed: \(failures.count)")
    exit(1)
}
print("ALL ENGINE CHECKS PASSED")
