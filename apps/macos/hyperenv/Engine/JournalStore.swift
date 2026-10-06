//
//  JournalStore.swift
//  hyperenv
//
//  The record of what is actually applied to the machine.
//
//  Deliberately plain JSON on disk rather than SwiftData. The applied state
//  describes mutations to files the app does not exclusively own; if the store
//  were the only record, a corrupted or badly migrated database would leave the
//  user with a modified `.zprofile` and no way to reverse it. This file is
//  greppable, survives a reinstall, and can be read with a text editor.
//

import Foundation

// MARK: - Transaction

nonisolated enum TransactionState: String, Sendable, Codable {
    /// Written before any file is touched. Its presence at launch means we
    /// crashed mid-apply.
    case pending
    case applied
    case unapplied
}

nonisolated struct ApplyTransaction: Sendable, Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let target: ApplyTarget

    let projectID: UUID
    let projectName: String
    let profileID: UUID
    let profileName: String

    /// Every key we own, with the value it had before we first touched it.
    /// This is what makes un-apply able to restore rather than merely unset.
    var managed: ManagedState
    /// Exactly what was written into `session.zsh`.
    var exports: EnvSet

    var sessionScriptHash: String
    var markerBlockHash: String
    var state: TransactionState

    var displayPath: String { "\(projectName)/\(profileName)" }
}

// MARK: - Store

nonisolated protocol JournalStore: Sendable {
    func loadCurrent() throws -> ApplyTransaction?
    func writePending(_ transaction: ApplyTransaction) throws
    func commit(_ transaction: ApplyTransaction) throws
    func clearCurrent() throws
    func pendingTransactions() throws -> [ApplyTransaction]
}

nonisolated struct FileJournalStore: JournalStore {
    let fileSystem: any FileSystemGateway

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        // Readable by a human at 2am with only a text editor available.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func loadCurrent() throws -> ApplyTransaction? {
        guard fileSystem.exists(Paths.currentJournal) else { return nil }
        let data = try fileSystem.readData(Paths.currentJournal)
        return try? decoder.decode(ApplyTransaction.self, from: data)
    }

    /// Records the complete intent — including the baseline — *before* any file
    /// is modified, so a crash mid-apply is recoverable rather than silent.
    func writePending(_ transaction: ApplyTransaction) throws {
        var pending = transaction
        pending.state = .pending
        let data = try encoder.encode(pending)
        try fileSystem.write(data, to: pendingURL(for: transaction.id), permissions: 0o600)
    }

    func commit(_ transaction: ApplyTransaction) throws {
        var committed = transaction
        if committed.state == .pending { committed.state = .applied }

        let data = try encoder.encode(committed)
        try fileSystem.write(data, to: Paths.currentJournal, permissions: 0o600)
        try fileSystem.write(data, to: historyURL(for: transaction.id), permissions: 0o600)
        try fileSystem.remove(pendingURL(for: transaction.id))
    }

    func clearCurrent() throws {
        try fileSystem.remove(Paths.currentJournal)
    }

    /// Orphans found here at launch mean a previous run died between writing
    /// its intent and committing.
    func pendingTransactions() throws -> [ApplyTransaction] {
        try fileSystem.contentsOfDirectory(Paths.historyDirectory)
            .filter { $0.lastPathComponent.hasSuffix(".pending.json") }
            .compactMap { url in
                guard let data = try? fileSystem.readData(url) else { return nil }
                return try? decoder.decode(ApplyTransaction.self, from: data)
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func pendingURL(for id: UUID) -> URL {
        Paths.historyDirectory.appending(path: "\(id.uuidString).pending.json")
    }

    private func historyURL(for id: UUID) -> URL {
        Paths.historyDirectory.appending(path: "\(id.uuidString).json")
    }
}
