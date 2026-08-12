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
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    private var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID } ?? projects.first
    }

    private var selectedProfile: Profile? {
        guard let project = selectedProject else { return nil }
        return project.profiles.first { $0.id == selectedProfileID }
            ?? project.sortedProfiles.first
    }

    /// Brings the selection IDs in line with what is actually on screen.
    ///
    /// The two lookups above fall back to the first item when their ID names
    /// nothing in the current data — at launch, when both IDs are still nil, and
    /// after switching project, when `selectedProfileID` still names a profile
    /// belonging to the *previous* one. The fallback keeps the detail pane
    /// populated, but the ID it resolved is not the ID `ProfileList` compares
    /// against, so the editor showed one profile while no card looked selected.
    ///
    /// Writing the resolved values back makes the two agree. It is idempotent,
    /// so re-running it on any change settles rather than oscillates.
    private func normalizeSelection() {
        if !projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = projects.first?.id
        }

        guard let project = selectedProject else {
            selectedProfileID = nil
            return
        }

        if !project.profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = project.sortedProfiles.first?.id
        }
    }

    var body: some View {
        // NavigationSplitView is the root, not a child of a VStack. On macOS it
        // expects to own the whole content area; nesting it makes it negotiate a
        // width it does not control, and it responds by collapsing columns as
        // the selection changes.
        //
        // The bar below is attached as a safe area inset instead, which reserves
        // its height so the last row of every column stays reachable. What made
        // the previous version look like it covered data was not the inset — it
        // was that the bar floated as a translucent capsule with margins around
        // it, so scrolling content showed through and around it. A full-width
        // opaque bar reads as chrome, and nothing is lost behind it.
        // Column visibility is stated, not inherited.
        //
        // AppKit persists the split view's subview frames per window and restores
        // them before the app can object. A build that laid the split view out
        // differently can therefore leave saved geometry that no longer describes
        // three columns — and the restored state wins on every subsequent launch,
        // which looks exactly like the data failing to load. Owning the value
        // means a bad restore cannot hide a column permanently.
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
                // Identity tied to the profile on purpose. Without it SwiftUI
                // reuses one VariableEditor across profiles and its @State comes
                // along: a filter typed for one profile hides the next profile's
                // variables, and a revealed secret stays revealed at the same
                // row of a different profile.
                VariableEditor(profile: profile, model: model)
                    .id(profile.id)
            } else {
                ContentUnavailableView(
                    "No profile selected", systemImage: "square.stack.3d.up",
                    description: Text("Choose a profile to edit its variables."))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                NoticeStack(model: model)

                ActiveProfileHUD(
                    model: model,
                    copied: $copied,
                    onRevert: { Task { await model.unapply() } })
            }
        }
        .task {
            await model.refresh()
            await model.seedIfNeeded(context: context)
            normalizeSelection()
            await model.checkDrift()
        }
        // Seeding and deletion both change what the IDs can legally point at.
        .onChange(of: projects.count) { _, _ in normalizeSelection() }
        .onChange(of: selectedProjectID) { _, _ in normalizeSelection() }
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
            // The same bar material the status bar uses, so the two read as one
            // piece of chrome rather than a panel sitting on another panel.
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.smooth(duration: 0.25), value: model.hookStatus)
        }
    }
}
