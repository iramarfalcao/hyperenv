//
//  SeedService.swift
//  hyperenv
//
//  Builds the Default project from the machine's existing environment.
//

import Foundation
import SwiftData

@MainActor
struct SeedService {
    let probe: any EnvironmentProbe

    init(probe: (any EnvironmentProbe)? = nil) {
        self.probe = probe ?? ZshLoginShellProbe(runner: RealProcessRunner())
    }

    static let defaultProjectName = "Default"
    static let defaultProfileName = "Default"

    struct SeedReport: Sendable {
        let imported: Int
        let excluded: [SeedBucket: Int]
        let interactiveOnly: Int
    }

    /// Reads the user's shell and files the result into Default/Default.
    ///
    /// Probed with HyperEnv bypassed. Without that, a re-sync performed while a
    /// profile is applied would absorb our own exports into the baseline, and
    /// the next un-apply would look like drift — a loop that quietly corrupts
    /// the record of what the user's environment originally was.
    @discardableResult
    func seed(into context: ModelContext) async throws -> SeedReport {
        let result = try await probe.probe(bypassHyperEnv: true)
        let classified = SeedFilter.classify(observed: result.observed, base: result.base)

        let project = try existingDefaultProject(in: context) ?? {
            let created = Project(name: Self.defaultProjectName, isDefault: true, sortIndex: -1)
            context.insert(created)
            return created
        }()

        let profile = project.profiles.first(where: { $0.isDefault }) ?? {
            let created = Profile(
                name: Self.defaultProfileName, kind: .systemDefault, isDefault: true)
            created.project = project
            context.insert(created)
            return created
        }()

        // A re-sync replaces the snapshot rather than merging: this profile
        // represents "what the machine looks like now", not accumulated history.
        for variable in profile.variables { context.delete(variable) }
        profile.variables.removeAll()

        // Every observed variable is recorded, not just the importable ones.
        // The Default profile is meant to answer "what does my machine
        // actually set?", and a nearly empty list answers nothing — a shell
        // that only configures brew and cargo produces almost entirely
        // derived and path-like variables. The unsafe ones are kept switched
        // off and labelled instead of being silently dropped.
        var index = 0
        for bucket in SeedBucket.allCases {
            for pair in classified.set(for: bucket).pairs {
                var note = bucket.isImportable ? nil : bucket.explanation
                if result.interactiveOnly.contains(pair.key) {
                    let extra = "Only set by interactive shells (.zshrc)."
                    note = note.map { "\($0) \(extra)" } ?? extra
                }

                let variable = EnvVariable(
                    key: pair.key.rawValue,
                    value: pair.value.rawValue,
                    isEnabled: bucket.isImportable,
                    isSecret: Self.looksSensitive(pair.key),
                    note: note,
                    sortIndex: index,
                    origin: .imported,
                    bucket: bucket)
                variable.profile = profile
                context.insert(variable)
                index += 1
            }
        }
        let importable = classified.importable

        try context.save()

        var excluded: [SeedBucket: Int] = [:]
        for bucket in SeedBucket.allCases where bucket != .user {
            let count = classified.set(for: bucket).count
            if count > 0 { excluded[bucket] = count }
        }

        return SeedReport(
            imported: importable.count,
            excluded: excluded,
            interactiveOnly: result.interactiveOnly.count)
    }

    static func hasSeeded(in context: ModelContext) -> Bool {
        (try? existingDefaultProjectStatic(in: context)) .flatMap { $0 } != nil
    }

    private func existingDefaultProject(in context: ModelContext) throws -> Project? {
        try Self.existingDefaultProjectStatic(in: context)
    }

    private static func existingDefaultProjectStatic(in context: ModelContext) throws -> Project? {
        var descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.isDefault })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Best-effort masking so tokens are not shown in plain sight by default.
    /// Presentation only — the applied `session.zsh` still holds plaintext.
    private static func looksSensitive(_ key: EnvKey) -> Bool {
        let name = key.rawValue.uppercased()
        return ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "APIKEY", "API_KEY",
                "PRIVATE", "CREDENTIAL", "AUTH"].contains { name.contains($0) }
    }
}
