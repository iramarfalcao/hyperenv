//
//  Models.swift
//  hyperenv
//
//  The persisted hierarchy: Project -> Profile -> EnvVariable.
//
//  SwiftData holds *desired* state only. What is actually applied to the
//  machine lives in a JSON journal on disk, because a corrupted or migrated
//  store must never leave the user with mutated dotfiles and no way back.
//

import Foundation
import SwiftData

// MARK: - Project

@Model
final class Project {
    var id: UUID = UUID()
    var name: String = ""
    /// Folder this project maps to on disk. `.env` files export here.
    var folderPath: String?
    /// The reserved project holding the machine's observed environment.
    var isDefault: Bool = false
    var createdAt: Date = Date()
    var sortIndex: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \Profile.project)
    var profiles: [Profile] = []

    init(
        name: String,
        folderPath: String? = nil,
        isDefault: Bool = false,
        sortIndex: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.folderPath = folderPath
        self.isDefault = isDefault
        self.createdAt = Date()
        self.sortIndex = sortIndex
    }

    var sortedProfiles: [Profile] {
        profiles.sorted { ($0.sortIndex, $0.name) < ($1.sortIndex, $1.name) }
    }
}

// MARK: - Profile

@Model
final class Profile {
    var id: UUID = UUID()
    var name: String = ""
    private var kindRaw: String = ProfileKind.custom.rawValue
    var isDefault: Bool = false
    var createdAt: Date = Date()
    var sortIndex: Int = 0

    var project: Project?

    @Relationship(deleteRule: .cascade, inverse: \EnvVariable.profile)
    var variables: [EnvVariable] = []

    init(
        name: String,
        kind: ProfileKind,
        isDefault: Bool = false,
        sortIndex: Int = 0
    ) {
        self.id = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.isDefault = isDefault
        self.createdAt = Date()
        self.sortIndex = sortIndex
    }

    /// Stored as a raw string so an unknown future case cannot make the store
    /// undecodable.
    var kind: ProfileKind {
        get { ProfileKind(rawValue: kindRaw) ?? .custom }
        set { kindRaw = newValue.rawValue }
    }

    var sortedVariables: [EnvVariable] {
        variables.sorted { ($0.sortIndex, $0.key) < ($1.sortIndex, $1.key) }
    }

    var enabledVariableCount: Int {
        variables.count { $0.isEnabled }
    }

    /// The Default profile is an observation of the machine, not configuration.
    /// Applying it would re-export a whole stale snapshot and freeze the user's
    /// environment, so the dangerous operation is gated while editing stays open.
    var canBeApplied: Bool { !isDefault }
}

// MARK: - EnvVariable

@Model
final class EnvVariable {
    var id: UUID = UUID()
    var key: String = ""
    var value: String = ""
    var isEnabled: Bool = true
    /// Hides the value in the UI. Note this is presentation only — the applied
    /// `session.zsh` must contain plaintext to be sourceable.
    var isSecret: Bool = false
    var note: String?
    var sortIndex: Int = 0
    private var originRaw: String = VariableOrigin.authored.rawValue
    /// Why a seeded variable was or was not considered importable. Retained so
    /// the Default profile can show the machine's *whole* environment while
    /// still keeping the unsafe parts switched off.
    private var bucketRaw: String?

    var profile: Profile?

    init(
        key: String,
        value: String,
        isEnabled: Bool = true,
        isSecret: Bool = false,
        note: String? = nil,
        sortIndex: Int = 0,
        origin: VariableOrigin = .authored,
        bucket: SeedBucket? = nil
    ) {
        self.id = UUID()
        self.key = key
        self.value = value
        self.isEnabled = isEnabled
        self.isSecret = isSecret
        self.note = note
        self.sortIndex = sortIndex
        self.originRaw = origin.rawValue
        self.bucketRaw = bucket?.rawValue
    }

    var origin: VariableOrigin {
        get { VariableOrigin(rawValue: originRaw) ?? .authored }
        set { originRaw = newValue.rawValue }
    }

    var bucket: SeedBucket? {
        get { bucketRaw.flatMap(SeedBucket.init(rawValue:)) }
        set { bucketRaw = newValue?.rawValue }
    }

    var isKeyValid: Bool { EnvKey.isValid(key) }
    var envKey: EnvKey? { EnvKey(key) }
}

// MARK: - Snapshots

/// A plain value copy of a profile, safe to hand to the engine actor.
///
/// `@Model` types are not `Sendable` and are bound to the `ModelContext` that
/// created them, so they must never cross an actor boundary. Everything the
/// engine needs is copied out here instead.
nonisolated struct ProfileSnapshot: Sendable, Equatable {
    let profileID: UUID
    let profileName: String
    let kind: ProfileKind
    let projectID: UUID
    let projectName: String
    let projectFolderPath: String?
    let variables: EnvSet

    var displayPath: String { "\(projectName)/\(profileName)" }
}

nonisolated enum SnapshotMapper {

    /// Builds a snapshot from a profile, keeping only variables that are
    /// enabled and have a name the shell can actually export.
    @MainActor
    static func snapshot(of profile: Profile) -> ProfileSnapshot? {
        guard let project = profile.project else { return nil }

        var set = EnvSet()
        for variable in profile.sortedVariables where variable.isEnabled {
            guard let key = variable.envKey else { continue }
            set[key] = EnvValue(variable.value)
        }

        return ProfileSnapshot(
            profileID: profile.id,
            profileName: profile.name,
            kind: profile.kind,
            projectID: project.id,
            projectName: project.name,
            projectFolderPath: project.folderPath,
            variables: set
        )
    }
}
