//
//  AppModel.swift
//  hyperenv
//
//  Bridges SwiftUI to the engine actor.
//

import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class AppModel {
    private let engine = ApplyEngine()
    private let seeder = SeedService()

    /// What the journal on disk says is applied — not what the UI wishes were
    /// applied. The filesystem is the source of truth for this.
    private(set) var applied: ApplyTransaction?
    private(set) var hookStatus: HookStatus = .notInstalled
    private(set) var drift: [DriftKind] = []
    private(set) var pendingRecoveries: [ApplyTransaction] = []
    private(set) var seedReport: SeedService.SeedReport?

    var isBusy = false
    var statusMessage: String?
    var errorMessage: String?

    var reloadCommand: String { "source \(Paths.displayPath(Paths.sessionScript))" }
    var undoCommand: String { "source \(Paths.displayPath(Paths.unsessionScript))" }

    var appliedProfileID: UUID? { applied?.profileID }

    func isApplied(_ profile: Profile) -> Bool { applied?.profileID == profile.id }

    // MARK: Lifecycle

    func refresh() async {
        applied = try? await engine.current()
        hookStatus = await engine.hookStatus()
        pendingRecoveries = (try? await engine.pendingRecoveries()) ?? []
    }

    /// Seeds Default/Default on first launch.
    func seedIfNeeded(context: ModelContext) async {
        guard !SeedService.hasSeeded(in: context) else { return }
        await withBusy("Reading your shell environment…") {
            seedReport = try await seeder.seed(into: context)
        }
    }

    func resync(context: ModelContext) async {
        await withBusy("Re-reading your shell environment…") {
            seedReport = try await seeder.seed(into: context)
            statusMessage = "Default profile re-synced."
        }
    }

    // MARK: Hook

    func installHook() async {
        await withBusy("Installing the shell hook…") {
            try await engine.installHook()
            hookStatus = await engine.hookStatus()
            statusMessage = "Hook installed in \(Paths.displayPath(Paths.zprofile))."
        }
    }

    func removeHook() async {
        await withBusy("Removing the shell hook…") {
            try await engine.removeHook()
            hookStatus = await engine.hookStatus()
            statusMessage = "Hook removed. Your dotfile is back to its original contents."
        }
    }

    // MARK: Apply

    func apply(_ profile: Profile) async {
        guard let snapshot = SnapshotMapper.snapshot(of: profile) else {
            errorMessage = "This profile is not attached to a project."
            return
        }
        await withBusy("Applying \(snapshot.displayPath)…") {
            let outcome = try await engine.apply(snapshot)
            applied = outcome.transaction
            hookStatus = await engine.hookStatus()
            statusMessage = "Applied \(snapshot.displayPath). Open a new terminal, or run the reload command."
            _ = outcome.plan
        }
    }

    func unapply() async {
        await withBusy("Reverting…") {
            _ = try await engine.unapply()
            applied = nil
            statusMessage = "Reverted. New terminals are back to your own environment."
        }
    }

    // MARK: Drift

    func checkDrift() async {
        drift = (try? await engine.detectDrift()) ?? []
    }

    var actionableDrift: [DriftKind] { drift.filter(\.isActionable) }

    // MARK: Helpers

    private func withBusy(_ message: String, _ work: () async throws -> Void) async {
        isBusy = true
        statusMessage = message
        errorMessage = nil
        defer { isBusy = false }

        do {
            try await work()
        } catch {
            statusMessage = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
