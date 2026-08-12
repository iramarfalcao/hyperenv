//
//  ProjectSidebar.swift
//  hyperenv
//

import AppKit
import SwiftData
import SwiftUI

struct ProjectSidebar: View {
    let projects: [Project]
    @Binding var selectedProjectID: UUID?
    let model: AppModel

    @Environment(\.modelContext) private var context
    @State private var renaming: Project?
    @State private var draftName = ""

    var body: some View {
        List(selection: $selectedProjectID) {
            Section("Projects") {
                ForEach(projects) { project in
                    row(for: project)
                        .tag(project.id)
                        .contextMenu { menu(for: project) }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button("New Project", systemImage: "plus", action: addProject)
            }
        }
        .sheet(item: $renaming) { project in
            RenameSheet(title: "Rename Project", name: $draftName) {
                project.name = draftName
                try? context.save()
            }
        }
    }

    private func row(for project: Project) -> some View {
        let liveKind = liveProfileKind(in: project)

        return HStack(spacing: 8) {
            Image(systemName: project.isDefault ? "desktopcomputer" : "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(project.isDefault ? Color.secondary : Color.accentColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 13))
                    .lineLimit(1)

                Text(subtitle(for: project))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 4)

            // Marks the project whose profile is currently live, in the colour
            // of the environment class — so "something is applied here" and
            // "and it is production" arrive together.
            if let liveKind {
                Circle()
                    .fill(liveKind.tint)
                    .frame(width: 7, height: 7)
                    .shadow(color: liveKind.tint.opacity(0.5), radius: 3)
                    .help("A \(liveKind.label.lowercased()) profile from this project is applied")
            }
        }
        .padding(.vertical, 3)
    }

    private func liveProfileKind(in project: Project) -> ProfileKind? {
        guard let applied = model.applied, applied.projectID == project.id else { return nil }
        return project.profiles.first { $0.id == applied.profileID }?.kind
            ?? ProfileKind(rawValue: applied.profileName.lowercased())
            ?? .custom
    }

    private func subtitle(for project: Project) -> String {
        if let path = project.folderPath {
            return Paths.displayPath(URL(fileURLWithPath: path))
        }
        let count = project.profiles.count
        return "\(count) profile\(count == 1 ? "" : "s")"
    }

    @ViewBuilder
    private func menu(for project: Project) -> some View {
        Button("Rename…") {
            draftName = project.name
            renaming = project
        }
        Button(project.folderPath == nil ? "Choose Folder…" : "Change Folder…") {
            chooseFolder(for: project)
        }
        if project.folderPath != nil {
            Button("Clear Folder") {
                project.folderPath = nil
                try? context.save()
            }
        }
        if !project.isDefault {
            Divider()
            Button("Delete", role: .destructive) { delete(project) }
        }
    }

    /// Drops the selection before the object it names goes away.
    ///
    /// Deleting a project cascades to its profiles and variables. If the
    /// selection still points into that subtree while SwiftData tears it down,
    /// the detail column is resolving a profile through an object that is being
    /// deleted underneath it.
    private func delete(_ project: Project) {
        if selectedProjectID == project.id {
            selectedProjectID = projects.first { $0.id != project.id }?.id
        }
        context.delete(project)
        try? context.save()
    }

    private func addProject() {
        let project = Project(name: "New Project", sortIndex: projects.count)
        context.insert(project)

        // A project with no profiles is a dead end, so start with the three the
        // hierarchy is built around.
        for (index, kind) in [ProfileKind.dev, .hml, .prd].enumerated() {
            let profile = Profile(name: kind.rawValue, kind: kind, sortIndex: index)
            profile.project = project
            context.insert(profile)
        }

        try? context.save()
        selectedProjectID = project.id
    }

    private func chooseFolder(for project: Project) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick the folder this project maps to. .env files export here."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        project.folderPath = url.path(percentEncoded: false)
        try? context.save()
    }
}

// MARK: - Rename sheet

struct RenameSheet: View {
    let title: String
    @Binding var name: String
    var onCommit: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(commit)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
    }

    private func commit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onCommit()
        dismiss()
    }
}
