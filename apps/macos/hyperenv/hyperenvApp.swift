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

    /// Mirrors the key Feedback reads, so the menu item reflects and sets the
    /// same preference rather than keeping a second copy of it.
    @AppStorage("soundEffectsEnabled") private var soundEffects = true

    /// Keeps the window inside the screen it opens on.
    ///
    /// `defaultSize` only applies to a window with no saved frame. AppKit
    /// restores the frame from a previous session first, and a frame saved on a
    /// larger display — or one written by an earlier build that laid this window
    /// out differently — comes back taller than the screen can show. The columns
    /// then extend past the bottom edge, which reads as a sidebar running off the
    /// screen rather than as a window that is simply too big.
    ///
    /// Only ever shrinks. A window the user has deliberately sized is left alone.
    private struct WindowFitter: NSViewRepresentable {
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            DispatchQueue.main.async { fit(view.window) }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}

        private func fit(_ window: NSWindow?) {
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            let visible = screen.visibleFrame
            let frame = window.frame
            guard frame.height > visible.height || frame.width > visible.width else { return }

            let fitted = NSSize(
                width: min(frame.width, visible.width),
                height: min(frame.height, visible.height))
            window.setFrame(
                NSRect(
                    x: visible.midX - fitted.width / 2,
                    y: visible.midY - fitted.height / 2,
                    width: fitted.width,
                    height: fitted.height),
                display: true)
        }
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(model: model)
                // Below this width the three columns cannot all hold their
                // minimum and the status bar summary starts truncating. The
                // height floor is deliberately lower than any window AppKit is
                // likely to restore, so a saved frame and this minimum never
                // fight over the layout.
                .frame(minWidth: 860, minHeight: 420)
                .background(WindowFitter())
        }
        .modelContainer(container)
        // Opens at HD, centred. AppKit clamps this to the screen's *visible*
        // frame, so on a 1920x1080 display the window comes up 1920x1050 rather
        // than sliding its bottom edge under the Dock — which is what made the
        // sidebar look taller than the screen.
        .defaultSize(width: 1920, height: 1080)
        .defaultPosition(.center)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Environment") {
                Button("Copy Reload Command") { model.copyReloadCommand() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.applied == nil)

                Button("Revert") { Task { await model.unapply() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.applied == nil || model.isBusy)

                Divider()

                Toggle("Sound Effects", isOn: $soundEffects)
                    .help("Play a sound when a profile is applied or reverted")
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
