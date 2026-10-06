//
//  HyperEnvApp.swift
//  hyperenv
//
//  HyperEnv 2 for macOS: the window and the Environment menu, over the same
//  Rust core as the Windows and Linux app and the `hyperenv` command.
//

import SwiftUI

@main
struct HyperEnvApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            MainView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Environment") {
                Button("Apply") { model.apply() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.selected == nil || model.isBusy)
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(model.appliedName == nil || model.isBusy)
                Divider()
                Button("Copy Reload Command") { model.copyReloadCommand() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.appliedName == nil)
                Divider()
                Button("Import .env…") { model.importDotenv() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(model.selected == nil)
                Button("Export .env…") { model.exportDotenv() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.selected == nil)
            }
        }
    }
}
