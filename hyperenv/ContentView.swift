//
//  ContentView.swift
//  hyperenv
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Project.sortIndex), SortDescriptor(\Project.name)])
    private var projects: [Project]

    let model: AppModel

    @State private var selectedProjectID: UUID?
    @State private var selectedProfileID: UUID?
    @State private var confirmingProfile: Profile?
    @State private var copied = false

    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID } ?? projects.first
    }

    private var selectedProfile: Profile? {
        guard let project = selectedProject else { return nil }
        return project.profiles.first { $0.id == selectedProfileID }
            ?? project.sortedProfiles.first
    }

    var body: some View {
        // The status bar and the banners are siblings of the split view, not an
        // overlay on top of it. Anything floating over the columns covers the
        // bottom row of the sidebar, the profile list and the variables table at
        // once, which is exactly where the data the user is reading lives.
        VStack(spacing: 0) {
            NavigationSplitView {
                ProjectSidebar(
                    projects: projects,
                    selectedProjectID: $selectedProjectID,
                    model: model)
                .navigationSplitViewColumnWidth(min: 208, ideal: 236, max: 320)
            } content: {
                if let project = selectedProject {
                    ProfileList(
                        project: project,
                        selectedProfileID: $selectedProfileID,
                        model: model,
                        onApply: requestApply)
                    .navigationSplitViewColumnWidth(min: 264, ideal: 300, max: 380)
                } else {
                    ContentUnavailableView(
                        "No project selected", systemImage: "folder",
                        description: Text("Choose a project from the sidebar."))
                }
            } detail: {
                if let profile = selectedProfile {
                    VariableEditor(profile: profile, model: model)
                } else {
                    ContentUnavailableView(
                        "No profile selected", systemImage: "square.stack.3d.up",
                        description: Text("Choose a profile to edit its variables."))
                }
            }

            NoticeStack(model: model)

            ActiveProfileHUD(
                model: model,
                copied: $copied,
                onRevert: { Task { await model.unapply() } })
        }
        .task {
            await model.refresh()
            await model.seedIfNeeded(context: context)
            await model.checkDrift()
        }
        .confirmationDialog(
            "Apply a production profile?",
            isPresented: .init(
                get: { confirmingProfile != nil },
                set: { if !$0 { confirmingProfile = nil } }),
            presenting: confirmingProfile
        ) { profile in
            Button("Apply \(profile.name)", role: .destructive) {
                let target = profile
                confirmingProfile = nil
                Task { await model.apply(target) }
            }
            Button("Cancel", role: .cancel) { confirmingProfile = nil }
        } message: { profile in
            Text("New terminals will point at production values from \(profile.name).")
        }
        .alert(
            "Something went wrong",
            isPresented: .init(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func requestApply(_ profile: Profile) {
        if profile.kind.requiresConfirmation {
            confirmingProfile = profile
        } else {
            Task { await model.apply(profile) }
        }
    }
}

// MARK: - Notices

/// Window-level messages about the machine's state, stacked directly above the
/// status bar. They collapse to nothing when there is nothing to say, so the
/// common case costs no vertical space at all.
private struct NoticeStack: View {
    let model: AppModel

    private var hasNotices: Bool {
        model.hookStatus != .installed || !model.actionableDrift.isEmpty
    }

    var body: some View {
        if hasNotices {
            VStack(spacing: 8) {
                if model.hookStatus != .installed {
                    SetupBanner(model: model)
                }
                if !model.actionableDrift.isEmpty {
                    DriftBanner(drift: model.actionableDrift, model: model)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Divider() }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.smooth(duration: 0.25), value: model.hookStatus)
        }
    }
}
