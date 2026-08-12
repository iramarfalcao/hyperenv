//
//  capture-window.swift
//  hyperenv
//
//  Renders the real window offscreen and reports what AppKit actually built.
//
//  Written because a layout fault cost several wrong diagnoses. The app looked
//  like it was failing to load data: the sidebar was empty, the columns were
//  blank, and yet a runtime probe showed every project present and every view
//  running its body with the right content. The cause was in the layout, and
//  layout is the one thing that cannot be inferred from logs.
//
//  Two things it reports that nothing else does:
//
//    * how many columns the split view actually built. A NavigationSplitView
//      given a `columnVisibility` binding silently builds two columns instead
//      of three, dropping the sidebar — and this only happens under a real
//      NSApplication run loop, so neither a bare NSHostingView nor a window
//      pumped with RunLoop.run(until:) reproduces it.
//    * a PNG of the window, via AppKit's own drawing rather than ImageRenderer,
//      which refuses to draw NSTableView-backed Lists at all.
//
//  Caveat worth knowing before trusting a blank region: `cacheDisplay` does not
//  draw vibrancy or Liquid Glass, so a sidebar or a glass card can come out
//  empty in the PNG while being perfectly fine on screen. The column count and
//  the view-tree dump are the trustworthy parts; the image is a hint.
//
//  Usage: Scripts/capture-window.sh <output-dir> [path/to/default.store]
//
//  With no store it uses an empty in-memory one. Pass a *copy* of a real store
//  to reproduce against real data — never the live file.
//

import AppKit
import SwiftData
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: swift Scripts/capture-window.swift <output-dir> [path/to/default.store]")
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let schema = Schema([Project.self, Profile.self, EnvVariable.self])
let configuration: ModelConfiguration =
    if arguments.count >= 3 {
        ModelConfiguration(schema: schema, url: URL(fileURLWithPath: arguments[2]))
    } else {
        ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    }

let container = try! ModelContainer(for: schema, configurations: [configuration])
let projectCount = (try? ModelContext(container).fetchCount(FetchDescriptor<Project>())) ?? -1
print("store holds \(projectCount) project(s)")

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false)
window.contentView = NSHostingView(
    rootView: ContentView(model: AppModel()).modelContainer(container))
window.orderFront(nil)

@MainActor
func splitView(in view: NSView) -> NSSplitView? {
    if let split = view as? NSSplitView { return split }
    for subview in view.subviews {
        if let found = splitView(in: subview) { return found }
    }
    return nil
}

@MainActor
func describe(_ view: NSView, depth: Int) {
    let name = String(describing: type(of: view))
    let frame = view.frame
    let notable = name.contains("Table") || name.contains("Scroll")
        || name.contains("Split") || name.contains("Host")
    guard notable || depth <= 3 else { return }

    var line = String(repeating: "  ", count: depth)
    line += "\(name) [\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))]"
    if let table = view as? NSTableView { line += "  rows=\(table.numberOfRows)" }
    if view.isHidden { line += "  HIDDEN" }
    print(line)

    guard depth < 10 else { return }
    for subview in view.subviews { describe(subview, depth: depth + 1) }
}

@MainActor
func report() {
    guard let root = window.contentView else { exit(1) }

    root.layoutSubtreeIfNeeded()

    let columns = splitView(in: root).map(\.arrangedSubviews.count) ?? -1
    print("")
    print("split view columns: \(columns)\(columns == 3 ? "" : "   <-- expected 3")")
    print("")
    describe(root, depth: 0)

    if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
        root.cacheDisplay(in: root.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            let url = outputDirectory.appending(path: "window.png")
            try? data.write(to: url)
            print("")
            print("wrote \(url.path(percentEncoded: false))")
        }
    }

    exit(columns == 3 ? 0 : 1)
}

// The window needs the real loop for a while: the fault above only appears once
// AppKit has driven a few layout passes.
let timer = Timer(timeInterval: 3.0, repeats: false) { _ in
    MainActor.assumeIsolated {
        report()
    }
}
RunLoop.main.add(timer, forMode: .common)
app.run()
