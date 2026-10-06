//
//  HyperEnvApp.swift
//  hyperenv
//
//  HyperEnv 2 for macOS: the window, the Environment menu and the menu bar
//  switcher, all over the same Rust core as the Windows and Linux app and the
//  `hyperenv` command.
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

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image("Icons/terminal")
                .renderingMode(.template)
                .accessibilityLabel("HyperEnv")
        }
    }
}

/// Switch profiles without opening the window.
private struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let applied = model.appliedName {
            Text("Active: \(applied)")
            Button("Undo") { model.undo() }.disabled(model.isBusy)
            Button("Copy Reload Command") { model.copyReloadCommand() }
        } else {
            Text("Nothing applied")
        }
        Divider()
        if model.profiles.isEmpty {
            Text("No profiles yet")
        } else {
            ForEach(model.profiles) { profile in
                Button(profile.isApplied ? "✓ \(profile.name)" : profile.name) { model.apply(profile.name) }
                    .disabled(model.isBusy || profile.isApplied)
            }
        }
        Divider()
        Button("Open HyperEnv") {
            NSApp.activate()
            openWindow(id: "main")
        }
        Button("Quit HyperEnv") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
