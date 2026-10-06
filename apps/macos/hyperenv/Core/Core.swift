//
//  Core.swift
//  hyperenv
//
//  The bridge to HyperEnv's Rust core (crates/ffi). The app sends the
//  `hyperenv` command's grammar and gets back the command's JSON envelope —
//  one contract for the window, the terminal and the editor plugins, already
//  covered by the command's tests. See crates/cli/README.md for the shapes.
//

import Foundation
import HyperEnvCore

struct CoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

nonisolated enum Core {

    /// Runs one command and decodes its `data`. Blocking — the commands that
    /// start the user's shell (apply, unapply, drift, plan) can take a moment,
    /// so the model calls this off the main actor.
    static func run<T: Decodable>(_ args: [String], as type: T.Type = T.self) throws -> T {
        let request = String(data: try JSONEncoder().encode(args), encoding: .utf8)!
        guard let raw = hyperenv_run(request) else { throw CoreError(message: "The core returned nothing.") }
        defer { hyperenv_free(raw) }
        let data = Data(String(cString: raw).utf8)

        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if envelope.ok, let value = envelope.data { return value }
        throw CoreError(message: envelope.error ?? "Unknown error.")
    }

    /// For commands whose `data` the caller does not need.
    static func run(_ args: [String]) throws {
        _ = try run(args, as: AnyDecodable.self)
    }

    private struct Envelope<T: Decodable>: Decodable {
        let ok: Bool
        let data: T?
        let error: String?
    }

    struct AnyDecodable: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

// MARK: - Shapes (as the command prints them)

nonisolated struct ProfileSummary: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let variableCount: Int
    let enabledCount: Int
    let isApplied: Bool
    let updatedAt: String
}

nonisolated struct Variable: Decodable, Identifiable, Hashable, Sendable {
    let key: String
    let value: String
    let isSecret: Bool
    let isEnabled: Bool
    var id: String { key }
}

nonisolated struct Status: Decodable, Sendable {
    struct Applied: Decodable, Sendable {
        let profileName: String
        let appliedAt: String
        let exportedKeys: [String]
    }

    struct DriftItem: Decodable, Sendable {
        let kind: String
        let key: String?
    }

    let version: String
    let shell: String
    let hook: String
    let hookDetail: String?
    let applied: Applied?
    let drift: [DriftItem]
    let pendingRecoveries: Int
    let reloadCommand: String
    let undoCommand: String
    let startupFile: String?
}

nonisolated struct Migration: Decodable, Sendable {
    let profiles: Int
}
