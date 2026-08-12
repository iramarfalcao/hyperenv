//
//  ApplyEngine.swift
//  hyperenv
//
//  Serialises every mutation of the machine's environment.
//

import Foundation

// MARK: - Supporting types

nonisolated enum HookStatus: Sendable, Equatable {
    case notInstalled
    case installed
    /// The block exists but is malformed — refuse to guess, offer a repair.
    case malformed(String)

    var isInstalled: Bool { self == .installed }
}

nonisolated struct ApplyOutcome: Sendable {
    let transaction: ApplyTransaction
    let plan: ApplyPlan
    /// Shells already open will not see this until they source it.
    let reloadCommand: String
}

// MARK: - Engine

actor ApplyEngine {
    private let fileSystem: any FileSystemGateway
    private let journal: any JournalStore
    private let probe: any EnvironmentProbe

    init(
        fileSystem: any FileSystemGateway = RealFileSystem(),
        journal: (any JournalStore)? = nil,
        probe: (any EnvironmentProbe)? = nil
    ) {
        self.fileSystem = fileSystem
        self.journal = journal ?? FileJournalStore(fileSystem: fileSystem)
        self.probe = probe ?? ZshLoginShellProbe(runner: RealProcessRunner())
    }

    // MARK: Current state

    func current() throws -> ApplyTransaction? {
        try journal.loadCurrent()
    }

    var reloadCommand: String {
        "source \(Paths.displayPath(Paths.sessionScript))"
    }

    var undoCommand: String {
        "source \(Paths.displayPath(Paths.unsessionScript))"
    }

    // MARK: Hook

    func hookStatus() -> HookStatus {
        do {
            let target = try fileSystem.resolvingSymlink(Paths.zprofile)
            guard let content = try fileSystem.readTextIfExists(target) else { return .notInstalled }
            let model = GuardedBlock.LineModel(parsing: content)
            return try GuardedBlock.findSpan(in: model.lines) == nil ? .notInstalled : .installed
        } catch let error as HyperEnvError {
            return .malformed(error.localizedDescription)
        } catch {
            return .malformed(error.localizedDescription)
        }
    }

    /// Adds the three-line block that sources our generated file.
    ///
    /// Runs once. Every later apply only rewrites `session.zsh`, so the user's
    /// own dotfile is never touched again — which is what keeps the recurring
    /// operation safe.
    func installHook() throws {
        try withLock {
            let target = try fileSystem.resolvingSymlink(Paths.zprofile)
            let existing = try fileSystem.readTextIfExists(target) ?? ""

            try backupOnce(content: existing)

            let body = SessionScriptRenderer.hookBody(
                sessionPath: Paths.shellRelative(Paths.sessionScript))
            let updated = try GuardedBlock.install(
                into: existing, body: body, path: Paths.displayPath(target))

            guard updated != existing else { return }
            // nil permissions: keep whatever mode the user's file already had.
            try fileSystem.write(Data(updated.utf8), to: target, permissions: nil)
        }
    }

    func removeHook() throws {
        try withLock {
            let target = try fileSystem.resolvingSymlink(Paths.zprofile)
            guard let existing = try fileSystem.readTextIfExists(target) else { return }

            let updated = try GuardedBlock.remove(
                from: existing, path: Paths.displayPath(target))
            guard updated != existing else { return }

            try fileSystem.write(Data(updated.utf8), to: target, permissions: nil)
        }
    }

    // MARK: Planning

    /// Computes what an apply would change, without touching anything.
    func plan(for snapshot: ProfileSnapshot) async throws -> ApplyPlan {
        let observed = try await probe.probe(bypassHyperEnv: true).observed
        let managed = try journal.loadCurrent()?.managed ?? ManagedState()
        return Reconciler.plan(
            desired: snapshot.variables, managed: managed, observed: observed)
    }

    // MARK: Apply

    func apply(_ snapshot: ProfileSnapshot) async throws -> ApplyOutcome {
        // Measured with HyperEnv bypassed so we read the user's real
        // configuration rather than our own previous output.
        let observed = try await probe.probe(bypassHyperEnv: true).observed
        let existing = try journal.loadCurrent()
        let plan = Reconciler.plan(
            desired: snapshot.variables,
            managed: existing?.managed ?? ManagedState(),
            observed: observed)

        let timestamp = ISO8601DateFormatter().string(from: Date())

        let sessionScript = SessionScriptRenderer.renderSession(
            variables: plan.exports,
            projectName: snapshot.projectName,
            profileName: snapshot.profileName,
            appliedAt: timestamp)

        let inverseScript = SessionScriptRenderer.renderInverse(
            restoring: plan.inverseEntries(), appliedAt: timestamp)

        var transaction = ApplyTransaction(
            id: UUID(),
            timestamp: Date(),
            target: .zshStartupFile,
            projectID: snapshot.projectID,
            projectName: snapshot.projectName,
            profileID: snapshot.profileID,
            profileName: snapshot.profileName,
            managed: plan.resultingState,
            exports: plan.exports,
            sessionScriptHash: fileSystem.sha256(sessionScript),
            markerBlockHash: "",
            state: .pending)

        try withLock {
            // 1. Intent first, with the full baseline. If we die after this
            //    point, the next launch can still reverse everything.
            try journal.writePending(transaction)

            // 2. Generated files. The inverse is written *now*, not at
            //    un-apply time, so it stays valid even if HyperEnv is deleted.
            try fileSystem.write(sessionScript, to: Paths.sessionScript, permissions: 0o600)
            try fileSystem.write(inverseScript, to: Paths.unsessionScript, permissions: 0o600)

            // 3. The user's dotfile, only if the hook is not already there.
            try installHookLocked()
            transaction.markerBlockHash = try currentMarkerHash()

            // 4. Commit.
            transaction.state = .applied
            try journal.commit(transaction)
        }

        return ApplyOutcome(
            transaction: transaction, plan: plan, reloadCommand: reloadCommand)
    }

    // MARK: Un-apply

    @discardableResult
    func unapply() async throws -> ApplyPlan {
        guard let existing = try journal.loadCurrent() else { return Reconciler.unapplyPlan(managed: ManagedState()) }

        let plan = Reconciler.unapplyPlan(managed: existing.managed)
        let timestamp = ISO8601DateFormatter().string(from: Date())

        let inverseScript = SessionScriptRenderer.renderInverse(
            restoring: plan.inverseEntries(), appliedAt: timestamp)

        // An empty session file rather than a deleted one: the hook checks for
        // readability, and leaving the file in place keeps re-applying instant.
        let emptySession = SessionScriptRenderer.renderSession(
            variables: EnvSet(),
            projectName: "—",
            profileName: "none",
            appliedAt: timestamp)

        try withLock {
            try fileSystem.write(inverseScript, to: Paths.unsessionScript, permissions: 0o600)
            try fileSystem.write(emptySession, to: Paths.sessionScript, permissions: 0o600)

            var closing = existing
            closing.state = .unapplied
            closing.managed = ManagedState()
            closing.exports = EnvSet()
            try journal.commit(closing)
            try journal.clearCurrent()
        }

        return plan
    }

    // MARK: Recovery

    /// Transactions that were recorded but never committed — evidence of a
    /// crash between writing the intent and finishing the work.
    func pendingRecoveries() throws -> [ApplyTransaction] {
        try journal.pendingTransactions()
    }

    // MARK: Drift

    func detectDrift() async throws -> [DriftKind] {
        guard let applied = try journal.loadCurrent(), applied.state == .applied else { return [] }
        var drift: [DriftKind] = []

        if let script = try fileSystem.readTextIfExists(Paths.sessionScript),
           fileSystem.sha256(script) != applied.sessionScriptHash {
            drift.append(.managedFileEdited)
        }

        if hookStatus() != .installed {
            drift.append(.markerBlockMissing)
        }

        // The check a checksum cannot make: the user adding their own
        // `export API_URL=…` after our block, which overrides us while every
        // file still hashes correctly.
        let observed = try await probe.probe(bypassHyperEnv: false).observed
        let semantic = Reconciler.semanticDrift(expected: applied.exports, observed: observed)
        if !semantic.isEmpty { drift.append(.semantic(semantic)) }

        return drift
    }

    // MARK: Internals

    private func withLock<T>(_ work: () throws -> T) throws -> T {
        try fileSystem.createDirectory(Paths.configDirectory)
        try fileSystem.createDirectory(Paths.historyDirectory)
        return try FileLock.withLock(at: Paths.lockFile, work)
    }

    /// The lock is not reentrant, so the apply path calls this instead of
    /// `installHook()`.
    private func installHookLocked() throws {
        let target = try fileSystem.resolvingSymlink(Paths.zprofile)
        let existing = try fileSystem.readTextIfExists(target) ?? ""
        try backupOnce(content: existing)

        let body = SessionScriptRenderer.hookBody(
            sessionPath: Paths.shellRelative(Paths.sessionScript))
        let updated = try GuardedBlock.install(
            into: existing, body: body, path: Paths.displayPath(target))

        guard updated != existing else { return }
        try fileSystem.write(Data(updated.utf8), to: target, permissions: nil)
    }

    private func currentMarkerHash() throws -> String {
        let target = try fileSystem.resolvingSymlink(Paths.zprofile)
        guard let content = try fileSystem.readTextIfExists(target),
              let body = try GuardedBlock.extractBody(from: content) else { return "" }
        return fileSystem.sha256(body.joined(separator: "\n"))
    }

    /// Keeps one pristine copy from before HyperEnv ever modified the file.
    /// Backups are never pruned.
    private func backupOnce(content: String) throws {
        guard !content.isEmpty else { return }
        let existing = try fileSystem.contentsOfDirectory(Paths.backupsDirectory)
        guard existing.isEmpty else { return }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        try fileSystem.write(
            content,
            to: Paths.backupsDirectory.appending(path: "zprofile.\(stamp).bak"),
            permissions: 0o600)
    }
}
