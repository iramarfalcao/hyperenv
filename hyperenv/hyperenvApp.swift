//
//  hyperenvApp.swift
//  hyperenv
//

import AppKit
import SwiftData
import SwiftUI

@main
struct hyperenvApp: App {
    private let container: ModelContainer

    init() {
        let schema = Schema([Project.self, Profile.self, EnvVariable.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            container = Self.recover(schema: schema, configuration: configuration, error: error)
        }
    }

    /// Recovers from a store this build cannot open.
    ///
    /// A store left behind by an incompatible schema is otherwise fatal on
    /// *every* launch, leaving the user with an app that cannot start and no
    /// way to fix it from the interface. The old file is moved aside rather
    /// than deleted, so nothing is destroyed and it can still be inspected.
    private static func recover(
        schema: Schema,
        configuration: ModelConfiguration,
        error: any Error
    ) -> ModelContainer {
        let storeURL = configuration.url
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        for suffix in ["", "-shm", "-wal"] {
            let source = URL(fileURLWithPath: storeURL.path(percentEncoded: false) + suffix)
            guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            let destination = URL(
                fileURLWithPath: storeURL.path(percentEncoded: false) + ".superseded-\(stamp)" + suffix)
            try? FileManager.default.moveItem(at: source, to: destination)
        }

        if let fresh = try? ModelContainer(for: schema, configurations: [configuration]) {
            return fresh
        }

        // Last resort: open in memory so the app still launches and can tell
        // the user what happened, instead of dying at startup.
        if let memory = try? ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]) {
            return memory
        }

        fatalError("Could not open or recreate the HyperEnv store: \(error)")
    }

    /// Shared so the window and the menu bar agree on what is applied.
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(model: model)
                // Below this the three columns cannot all hold their minimum
                // width, and the status bar summary starts truncating.
                .frame(minWidth: 860, minHeight: 480)
        }
        .modelContainer(container)
        .defaultSize(width: 1120, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Environment") {
                Button("Copy Reload Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.reloadCommand, forType: .string)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.applied == nil)

                Button("Revert") { Task { await model.unapply() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.applied == nil || model.isBusy)
            }
        }

        MenuBarExtra {
            MenuBarView(model: model)
                .modelContainer(container)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}
