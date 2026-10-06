//
//  Authoring.swift
//  hyperenv
//
//  The rules behind "New Project", "New Profile", "Duplicate", "Add Variable"
//  and "Import". They used to live inside the views, which meant the only way
//  to prove them was to click. Here, `Tests/ModelChecks` runs the same code
//  the buttons run.
//
//  Nothing here saves. The caller decides when the context is committed, as
//  the views always did.
//

import Foundation
import SwiftData

@MainActor
enum Authoring {

    /// Trims the name; a blank one creates nothing.
    @discardableResult
    static func createProject(
        named rawName: String, sortIndex: Int, in context: ModelContext
    ) -> Project? {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let project = Project(name: name, sortIndex: sortIndex)
        context.insert(project)
        return project
    }

    /// Trims the name; a blank one creates nothing. The profile lands at the
    /// end of the project's list.
    @discardableResult
    static func createProfile(
        named rawName: String, kind: ProfileKind, in project: Project, context: ModelContext
    ) -> Profile? {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let profile = Profile(name: name, kind: kind, sortIndex: project.profiles.count)
        profile.project = project
        context.insert(profile)
        return profile
    }

    /// Copies a profile into a normal, appliable one. This is how the Default
    /// snapshot becomes a usable starting point, which is why a system-default
    /// source becomes `.custom` and every copied variable is `.authored`.
    @discardableResult
    static func duplicate(_ profile: Profile, context: ModelContext) -> Profile {
        let copy = Profile(
            name: "\(profile.name) copy",
            kind: profile.kind == .systemDefault ? .custom : profile.kind,
            sortIndex: profile.project?.profiles.count ?? 0)
        copy.project = profile.project
        context.insert(copy)

        for variable in profile.sortedVariables {
            let duplicated = EnvVariable(
                key: variable.key,
                value: variable.value,
                isEnabled: variable.isEnabled,
                isSecret: variable.isSecret,
                note: variable.note,
                sortIndex: variable.sortIndex,
                origin: .authored)
            duplicated.profile = copy
            context.insert(duplicated)
        }
        return copy
    }

    /// A blank row at the end of the list, for the user to fill in.
    @discardableResult
    static func addVariable(to profile: Profile, context: ModelContext) -> EnvVariable {
        let variable = EnvVariable(key: "", value: "", sortIndex: profile.variables.count)
        variable.profile = profile
        context.insert(variable)
        return variable
    }

    /// Merges imported entries: a key the profile already has gets its value
    /// replaced in place (origin and flags untouched); a new key is created as
    /// `.imported`.
    static func merge(_ entries: [DotenvEntry], into profile: Profile, context: ModelContext) {
        var existing: [String: EnvVariable] = [:]
        for variable in profile.variables { existing[variable.key] = variable }

        for entry in entries {
            if let match = existing[entry.key.rawValue] {
                match.value = entry.value.rawValue
            } else {
                let variable = EnvVariable(
                    key: entry.key.rawValue,
                    value: entry.value.rawValue,
                    sortIndex: profile.variables.count,
                    origin: .imported)
                variable.profile = profile
                context.insert(variable)
                existing[entry.key.rawValue] = variable
            }
        }
    }
}
