//
//  Reconciler.swift
//  hyperenv
//
//  Computes what an apply or un-apply must actually do.
//
//  Pure, because this is where the correctness of un-apply is decided and it
//  needs to be exhaustively testable without a filesystem.
//

import Foundation

// MARK: - Managed state

/// The keys HyperEnv currently owns, each paired with the value it had *before*
/// HyperEnv first touched it.
nonisolated struct ManagedState: Sendable, Codable, Equatable {
    private(set) var baselines: [EnvKey: PriorState]

    init(baselines: [EnvKey: PriorState] = [:]) { self.baselines = baselines }

    var managedKeys: [EnvKey] { baselines.keys.sorted() }
    var isEmpty: Bool { baselines.isEmpty }

    func isManaged(_ key: EnvKey) -> Bool { baselines[key] != nil }
    func baseline(for key: EnvKey) -> PriorState? { baselines[key] }

    fileprivate mutating func capture(_ key: EnvKey, _ state: PriorState) {
        // Guarded rather than assigned: re-capturing is the bug this whole type
        // exists to prevent.
        guard baselines[key] == nil else { return }
        baselines[key] = state
    }

    fileprivate mutating func release(_ key: EnvKey) { baselines.removeValue(forKey: key) }
}

// MARK: - Plan

nonisolated struct ApplyPlan: Sendable, Equatable {
    /// Exactly what `session.zsh` should export.
    let exports: EnvSet
    /// Keys becoming managed now, with the prior value to remember.
    let captures: [EnvKey: PriorState]
    /// Keys no longer wanted, with the value to put back.
    let restores: [EnvKey: PriorState]
    /// The managed state after this plan is committed.
    let resultingState: ManagedState

    var isNoOp: Bool { captures.isEmpty && restores.isEmpty }

    /// Entries for the inverse script, covering both what we are taking over
    /// and what we are handing back.
    func inverseEntries() -> [(key: EnvKey, prior: PriorState)] {
        var merged = captures
        for (key, state) in restores { merged[key] = state }
        return merged.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }
}

// MARK: - Reconciler

nonisolated enum Reconciler {

    /// Plans an apply.
    ///
    /// - Parameters:
    ///   - desired: the variables the profile wants exported.
    ///   - managed: what HyperEnv already owns.
    ///   - observed: the user's environment measured with HyperEnv bypassed, so
    ///     it reflects their real configuration rather than our own output.
    ///
    /// The invariant: a key's baseline is captured **once**, on the
    /// unmanaged-to-managed transition, and discarded only on the way back. A
    /// key we already own is never re-measured — doing so would record our own
    /// applied value as though it were the user's original, so a later un-apply
    /// would "restore" a value the user never had.
    static func plan(desired: EnvSet, managed: ManagedState, observed: EnvSet) -> ApplyPlan {
        var state = managed
        var captures: [EnvKey: PriorState] = [:]
        var restores: [EnvKey: PriorState] = [:]

        for key in desired.keys where !state.isManaged(key) {
            let prior: PriorState = if let existing = observed[key] {
                .present(existing)
            } else {
                .absent
            }
            captures[key] = prior
            state.capture(key, prior)
        }

        for key in state.managedKeys where !desired.contains(key) {
            if let baseline = state.baseline(for: key) {
                restores[key] = baseline
            }
            state.release(key)
        }

        return ApplyPlan(
            exports: desired,
            captures: captures,
            restores: restores,
            resultingState: state
        )
    }

    /// Plans a full un-apply: hand every managed key back to its baseline.
    static func unapplyPlan(managed: ManagedState) -> ApplyPlan {
        var restores: [EnvKey: PriorState] = [:]
        for key in managed.managedKeys {
            restores[key] = managed.baseline(for: key)
        }
        return ApplyPlan(
            exports: EnvSet(),
            captures: [:],
            restores: restores,
            resultingState: ManagedState()
        )
    }

    // MARK: Drift

    /// Compares what the shell actually reports against what we exported.
    ///
    /// Catches the failure a checksum never will: the user adding
    /// `export API_URL=…` to their dotfile *after* our block, which silently
    /// overrides us while every file still hashes correctly.
    static func semanticDrift(expected: EnvSet, observed: EnvSet) -> [EnvKey: DriftDetail] {
        var drift: [EnvKey: DriftDetail] = [:]
        for (key, expectedValue) in expected.pairs {
            guard let actual = observed[key] else {
                drift[key] = .missing(expected: expectedValue)
                continue
            }
            if actual != expectedValue {
                drift[key] = .shadowed(expected: expectedValue, actual: actual)
            }
        }
        return drift
    }
}

nonisolated enum DriftDetail: Sendable, Equatable {
    /// Exported by us, absent from the shell.
    case missing(expected: EnvValue)
    /// Exported by us, but something later assigned a different value.
    case shadowed(expected: EnvValue, actual: EnvValue)
}

// MARK: - File-level drift

nonisolated enum DriftKind: Sendable, Equatable {
    /// Our generated file was hand-edited.
    case managedFileEdited
    /// The block is gone from the dotfile while the journal says applied.
    case markerBlockMissing
    /// The dotfile changed outside our span — expected, not a problem.
    case dotfileChangedOutsideBlock
    /// The shell reports different values than we exported.
    case semantic([EnvKey: DriftDetail])
    /// A launchd apply did not survive the session restart.
    case launchdSessionExpired

    var isActionable: Bool {
        switch self {
        case .dotfileChangedOutsideBlock: false
        default: true
        }
    }
}
