//
//  LayoutChecks
//
//  Guards against a view asking for more width than a window can give it.
//
//  This exists because of a real failure: the snapshot profile holds PATH, a
//  400+ character value. A plain TextField reports an ideal width that fits its
//  whole contents, so one row asked for roughly 3300pt inside a column a fifth
//  that wide. The split view could not satisfy that, and the window rendered
//  with every column's content pushed off screen — indistinguishable from the
//  data failing to load, and slow to find by eye.
//
//  It measures the *row*, deliberately. Wrapping the row in the editor's List
//  and measuring that reports a clamped ~830pt no matter how wide the row wants
//  to be, so an editor-level assertion passes with the bug present and proves
//  nothing.
//
//  Most of it needs no window. The height check does: a hosting view left to
//  its own devices reports its fitting size and never reproduces the overflow.
//

import AppKit
import SwiftData
import SwiftUI

@MainActor
final class Checks {
    var passed = 0
    var failed = 0

    func expect(_ label: String, width: CGFloat, atMost limit: CGFloat) {
        if width <= limit {
            passed += 1
        } else {
            failed += 1
            print("FAIL \(label)\n     wanted at most \(Int(limit))pt, asked for \(Int(width))pt")
        }
    }

    @MainActor
    func width(@ViewBuilder _ content: () -> some View) -> CGFloat {
        NSHostingView(rootView: content()).fittingSize.width
    }
}

@MainActor
func makeVariable(key: String, value: String) -> (ModelContainer, EnvVariable) {
    let schema = Schema([Project.self, Profile.self, EnvVariable.self])
    let container = try! ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
    let context = container.mainContext

    let project = Project(name: "Default", isDefault: true, sortIndex: -1)
    context.insert(project)
    let profile = Profile(name: "Default", kind: .systemDefault, isDefault: true, sortIndex: 0)
    profile.project = project
    context.insert(profile)

    let variable = EnvVariable(
        key: key, value: value, isEnabled: false,
        sortIndex: 0, origin: .imported, bucket: .pathLike)
    variable.profile = profile
    context.insert(variable)
    try! context.save()

    return (container, variable)
}

// The window-backed check needs an app object, but not a visible one.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let checks = Checks()

/// A realistic 412-character PATH, the length actually seeded from a machine.
let longPath = String(
    repeating: "/opt/homebrew/bin:/var/run/com.apple.security.cryptexd/codex.system:",
    count: 8
).prefix(412).description

// The window cannot be narrower than 860pt, and the detail column is only a
// part of that. A row that asks for more than the whole window is already
// unsatisfiable, so this is a generous ceiling rather than a tight one.
let ceiling: CGFloat = 860

for (label, key, value) in [
    ("row holding a 412-character PATH", "PATH", longPath),
    ("row holding a 133-character FPATH", "FPATH", String(longPath.prefix(133))),
    ("row holding a long name", String(repeating: "VERY_LONG_NAME_", count: 12), "x"),
    ("row holding ordinary values", "LANG", "en_US.UTF-8"),
] {
    let (container, variable) = makeVariable(key: key, value: value)
    checks.expect(
        label,
        width: checks.width {
            VariableRow(variable: variable, onDelete: {})
                .modelContainer(container)
        },
        atMost: ceiling)
}

// A secret is rendered by a SecureField rather than a TextField, so it is a
// separate path through the same layout and can regress on its own.
let (secretContainer, secret) = makeVariable(key: "TOKEN", value: longPath)
secret.isSecret = true
checks.expect(
    "row holding a long masked value",
    width: checks.width {
        VariableRow(variable: secret, onDelete: {})
            .modelContainer(secretContainer)
    },
    atMost: ceiling)

// MARK: - Nothing may be taller than the window

// The second failure this file exists for. `.fixedSize(vertical: true)` on a
// long Text measures against a near-zero proposed width, wraps into a ~2000pt
// column, and drags the whole split view with it — inside a 472pt window. The
// columns then extend far past the bottom edge and the app looks empty.
//
// The snapshot notice is only shown for the Default profile, so only the
// Default project was affected, which made it look like a data problem.
@MainActor
func splitViewHeight(windowHeight: CGFloat) -> CGFloat {
    let (container, variable) = makeVariable(key: "PATH", value: longPath)
    guard let profile = variable.profile else { return -1 }

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1107, height: windowHeight),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    let hosting = NSHostingView(
        rootView: NavigationSplitView {
            Text("sidebar")
        } content: {
            Text("profiles")
        } detail: {
            VariableEditor(profile: profile, model: AppModel())
        }
        .modelContainer(container))
    // Track the window the way a WindowGroup's hosting view does; without this
    // the hosting view keeps its own fitting height and the test proves nothing.
    hosting.autoresizingMask = [.width, .height]
    hosting.sizingOptions = []
    window.contentView = hosting
    window.setContentSize(NSSize(width: 1107, height: windowHeight))
    window.orderFront(nil)

    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    window.contentView?.layoutSubtreeIfNeeded()

    func find(_ view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for sub in view.subviews {
            if let found = find(sub) { return found }
        }
        return nil
    }
    let height = find(window.contentView!)?.frame.height ?? -1
    window.orderOut(nil)
    return height
}

// A little slack for the titlebar the split view sits under; the failure mode
// this guards against overshoots by a factor of four, not by a few points.
let windowHeight: CGFloat = 472
let measured = splitViewHeight(windowHeight: windowHeight)
if measured > 0 && measured <= windowHeight + 80 {
    checks.passed += 1
} else {
    checks.failed += 1
    print("FAIL the editor fits the window's height")
    print("     window is \(Int(windowHeight))pt, split view laid out at \(Int(measured))pt")
}

print("")
print("passed: \(checks.passed)")
if checks.failed > 0 {
    print("failed: \(checks.failed)")
    exit(1)
}
print("ALL LAYOUT CHECKS PASSED")
