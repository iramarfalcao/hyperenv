//
//  DemoWindow
//
//  Opens the real app window filled with representative data, so screenshots can
//  be taken of the actual interface without photographing somebody's machine.
//
//  Two reasons this is not just "launch the app and press shift-command-4":
//
//    * The real store holds the user's own environment — API keys, internal
//      hostnames, home directory paths. None of that belongs in a picture on a
//      public website.
//    * The real store also holds whatever they happened to be doing, which is
//      rarely a clean illustration of what the app is for.
//
//  Everything here is in memory. It reads nothing and writes nothing.
//
//  Usage: Scripts/demo-window.sh   (keeps the window open for capture)
//

import AppKit
import SwiftData
import SwiftUI

@MainActor
func demoContainer() -> (ModelContainer, UUID, UUID) {
    let schema = Schema([Project.self, Profile.self, EnvVariable.self])
    let container = try! ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    let context = container.mainContext

    // The snapshot project, as the app seeds it on first launch.
    let snapshot = Project(name: "Default", isDefault: true, sortIndex: 2)
    context.insert(snapshot)
    let snapshotProfile = Profile(
        name: "Default", kind: .systemDefault, isDefault: true, sortIndex: 0)
    snapshotProfile.project = snapshot
    context.insert(snapshotProfile)

    let acme = Project(name: "acme-api", sortIndex: 1)
    context.insert(acme)
    for (index, kind) in [ProfileKind.dev, .hml, .prd].enumerated() {
        let profile = Profile(name: kind.rawValue, kind: kind, sortIndex: index)
        profile.project = acme
        context.insert(profile)
    }

    // First in the list so the window opens on a project that has something
    // in it. The app normally puts Default first; the order of projects is not
    // a claim about behaviour, and an empty pane makes a poor illustration.
    let payments = Project(name: "payments", sortIndex: 0)
    context.insert(payments)

    var live: Profile?
    for (index, kind) in [ProfileKind.dev, .hml, .prd].enumerated() {
        let profile = Profile(name: kind.rawValue, kind: kind, sortIndex: index)
        profile.project = payments
        context.insert(profile)
        if kind == .dev { live = profile }
    }

    // Deliberately ordinary values, and deliberately not shaped like any real
    // provider's token. A secret scanner cannot tell an invented key from a
    // leaked one, so a realistic-looking placeholder gets a push blocked — which
    // is exactly what happened to the first version of this list.
    let variables: [(String, String, Bool, Bool)] = [
        ("DATABASE_URL", "postgres://localhost:5432/payments_dev", true, false),
        ("API_BASE_URL", "https://api.dev.example.com", true, false),
        ("AWS_PROFILE", "payments-dev", true, false),
        ("AWS_REGION", "eu-west-1", true, false),
        ("REDIS_URL", "redis://localhost:6379/0", true, false),
        ("PAYMENT_API_TOKEN", "example-token-not-a-real-credential", true, true),
        ("LOG_LEVEL", "debug", true, false),
        ("FEATURE_NEW_CHECKOUT", "1", false, false),
    ]
    for (index, entry) in variables.enumerated() {
        let variable = EnvVariable(
            key: entry.0,
            value: entry.1,
            isEnabled: entry.2,
            isSecret: entry.3,
            sortIndex: index)
        variable.profile = live
        context.insert(variable)
    }

    try! context.save()
    return (container, payments.id, live!.id)
}

/// The journal entry the status bar reads, staged rather than written to disk.
@MainActor
func stagedTransaction(projectID: UUID, profileID: UUID) -> ApplyTransaction {
    var exports = EnvSet()
    for pair in [
        ("DATABASE_URL", "postgres://localhost:5432/payments_dev"),
        ("API_BASE_URL", "https://api.dev.example.com"),
        ("AWS_PROFILE", "payments-dev"),
        ("AWS_REGION", "eu-west-1"),
        ("REDIS_URL", "redis://localhost:6379/0"),
        ("PAYMENT_API_TOKEN", "example-token-not-a-real-credential"),
        ("LOG_LEVEL", "debug"),
    ] {
        if let key = EnvKey(pair.0) { exports[key] = EnvValue(pair.1) }
    }

    return ApplyTransaction(
        id: UUID(),
        timestamp: Date(timeIntervalSince1970: 1_786_000_000),
        target: .zshStartupFile,
        projectID: projectID,
        projectName: "payments",
        profileID: profileID,
        profileName: "dev",
        managed: ManagedState(),
        exports: exports,
        sessionScriptHash: "",
        markerBlockHash: "",
        state: .applied)
}

/// Which screen to show. The two sheets are hosted directly rather than driven
/// through the interface: scripting clicks needs Accessibility permission and
/// produces the same pixels, with more that can go wrong.
enum Scene: String {
    case main
    case newProject = "new-project"
    case newProfile = "new-profile"

    var size: NSSize {
        switch self {
        case .main: NSSize(width: 1280, height: 800)
        case .newProject: NSSize(width: 380, height: 210)
        case .newProfile: NSSize(width: 380, height: 262)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let scene = Scene(rawValue: CommandLine.arguments.dropFirst().first ?? "main") ?? .main
let (container, projectID, profileID) = demoContainer()
let model = AppModel(staging: stagedTransaction(projectID: projectID, profileID: profileID))

let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: scene.size),
    styleMask: scene == .main
        ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        : [.titled, .fullSizeContentView],
    backing: .buffered,
    defer: false)
window.title = "HyperEnv"

switch scene {
case .main:
    window.contentView = NSHostingView(
        rootView: ContentView(model: model).modelContainer(container))
case .newProject:
    window.contentView = NSHostingView(
        rootView: NameSheet(
            title: "New Project",
            prompt: "Name this project after the codebase or client it belongs to.",
            confirmLabel: "Create",
            name: .constant("payments"),
            onCommit: {}))
case .newProfile:
    window.contentView = NSHostingView(
        rootView: ProfileSheet(
            title: "New Profile",
            confirmLabel: "Create",
            name: .constant("prd"),
            kind: .constant(.prd),
            onCommit: {}))
}

window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

print("demo window open (\(scene.rawValue)) — capture it, then press ctrl-c")
app.run()
