//
//  MenuBarView.swift
//  hyperenv
//
//  Quick switching without bringing the main window forward.
//

import AppKit
import SwiftData
import SwiftUI

struct MenuBarView: View {
    let model: AppModel

    @Query(sort: [SortDescriptor(\Project.sortIndex), SortDescriptor(\Project.name)])
    private var projects: [Project]

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let applied = model.applied {
                Text("Active: \(applied.displayPath)")
                Text("\(applied.exports.count) variable\(applied.exports.count == 1 ? "" : "s") in new terminals")

                Divider()

                Button("Copy Reload Command") { model.copyReloadCommand() }
                Button("Revert") { Task { await model.unapply() } }
                    .disabled(model.isBusy)
            } else {
                Text("Nothing applied")
            }

            Divider()

            let switchable = projects.filter { !$0.isDefault }
            if switchable.isEmpty {
                Text("No projects yet")
            } else {
                ForEach(switchable) { project in
                    Menu(project.name) {
                        ForEach(project.sortedProfiles.filter(\.canBeApplied)) { profile in
                            Button("\(profile.name)  —  \(profile.kind.label)") {
                                Task { await model.apply(profile) }
                            }
                            .disabled(model.isBusy || model.isApplied(profile))
                        }
                    }
                }
            }

            Divider()

            Button("Open HyperEnv") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            Button("Quit HyperEnv") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .task { await model.refresh() }
    }
}

/// The status item's own label.
///
/// Menu bar icons are rendered as monochrome templates, so state is carried by
/// *shape*, not colour: production gets an outline nothing else in the bar
/// shares, and is legible at a glance from across the desk.
struct MenuBarLabel: View {
    let model: AppModel

    private var symbol: String {
        guard let name = model.applied?.profileName else { return "circle.dashed" }
        let kind = ProfileKind(rawValue: name.lowercased()) ?? .custom
        return kind == .prd ? "exclamationmark.triangle.fill" : "circle.fill"
    }

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel(model.applied.map { "HyperEnv: \($0.displayPath) applied" }
                                ?? "HyperEnv: nothing applied")
    }
}
