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
    @State private var isCreating = false
    @State private var newProjectName = ""

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
                Button("New Project", systemImage: "plus") {
                    newProjectName = ""
                    isCreating = true
                }
                .help("Create a project")
            }
        }
        .sheet(isPresented: $isCreating) {
            NameSheet(
                title: "New Project",
                prompt: "Name this project after the codebase or client it belongs to.",
                confirmLabel: "Create",
                name: $newProjectName,
                onCommit: addProject)
        }
        .sheet(item: $renaming) { project in
            NameSheet(title: "Rename Project", name: $draftName) {
                project.name = draftName.trimmingCharacters(in: .whitespaces)
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
                    .transition(.scale.combined(with: .opacity))
                    .help("A \(liveKind.label.lowercased()) profile from this project is applied")
            }
        }
        .padding(.vertical, 3)
        .animation(.smooth(duration: 0.28), value: liveKind)
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

    /// Creates an empty project under the name the user typed.
    ///
    /// No profiles are created for it. Guessing at dev/hml/prd meant every new
    /// project arrived with three profiles most people then had to rename or
    /// delete, and a profile that exists but holds nothing is indistinguishable
    /// from one that was configured and left empty. The profile list's empty
    /// state offers the three as one click each instead.
    private func addProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }

        let project = Project(name: name, sortIndex: projects.count)
        context.insert(project)
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

// MARK: - Naming sheet

/// Asks for a name, for both creating and renaming.
struct NameSheet: View {
    let title: String
    var prompt: String?
    var confirmLabel = "Save"
    @Binding var name: String
    var onCommit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let prompt {
                    Text(prompt)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .focused($isFocused)
                .onSubmit(commit)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: commit)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
        .onAppear { isFocused = true }
    }

    private func commit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onCommit()
        dismiss()
    }
}
