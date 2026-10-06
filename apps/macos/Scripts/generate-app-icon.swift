#!/usr/bin/env swift
//
//  generate-app-icon.swift
//  hyperenv
//
//  Renders the app icon.
//
//  The icon is generated rather than hand-drawn so it stays reproducible: the
//  three dots use the exact same tints the app uses for dev / hml / prd, and
//  changing one of those colours here changes both.
//
//  One source, three destinations, so the mark is the same everywhere the app
//  shows up:
//    hyperenv/Assets.xcassets/AppIcon.appiconset  the app itself
//    assets/HyperEnv.icns                         the disk image's volume icon
//    assets/icon-1024.png                         README and documentation
//
//  Usage: swift Scripts/generate-app-icon.swift
//

import AppKit
import SwiftUI

// MARK: - Palette

private let plateTop = Color(red: 0.286, green: 0.361, blue: 0.949)   // #4A5CF2
private let plateBottom = Color(red: 0.435, green: 0.176, blue: 0.855) // #6F2DDA

private let devTint = Color(red: 0.204, green: 0.780, blue: 0.349)  // green
private let hmlTint = Color(red: 1.000, green: 0.624, blue: 0.039)  // orange
private let prdTint = Color(red: 1.000, green: 0.271, blue: 0.227)  // red

// MARK: - Artwork

/// The icon, laid out in a fixed 1024-point space and scaled at render time so
/// every exported size is pixel-identical in proportion.
private struct AppIcon: View {
    static let canvas: CGFloat = 1024
    /// macOS icons sit on a plate inset from the canvas edge.
    static let inset: CGFloat = 100

    private var plate: CGFloat { Self.canvas - Self.inset * 2 }

    var body: some View {
        ZStack {
            Color.clear

            RoundedRectangle(cornerRadius: plate * 0.2237, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [plateTop, plateBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                .overlay {
                    // A single specular sweep keeps the plate from reading flat
                    // at 512pt without adding visual noise at 16pt.
                    RoundedRectangle(cornerRadius: plate * 0.2237, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.22), .clear],
                                startPoint: .top,
                                endPoint: .center))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: plate * 0.2237, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: plate * 0.006)
                }
                .frame(width: plate, height: plate)
                .shadow(color: .black.opacity(0.28), radius: plate * 0.04, y: plate * 0.022)
                .overlay { mark.frame(width: plate, height: plate) }
        }
        .frame(width: Self.canvas, height: Self.canvas)
    }

    /// A shell prompt over the three environment tints — the whole product in
    /// one glyph: a terminal, and which environment it is pointed at.
    private var mark: some View {
        Canvas { context, size in
            let s = size.width / 824  // artwork was laid out in an 824 plate
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * s, y: (y - 16) * s)
            }

            var chevron = Path()
            chevron.move(to: p(244, 218))
            chevron.addLine(to: p(376, 348))
            chevron.addLine(to: p(244, 478))
            context.stroke(
                chevron,
                with: .color(.white),
                style: StrokeStyle(lineWidth: 62 * s, lineCap: .round, lineJoin: .round))

            var underscore = Path()
            underscore.move(to: p(452, 448))
            underscore.addLine(to: p(580, 448))
            context.stroke(
                underscore,
                with: .color(.white),
                style: StrokeStyle(lineWidth: 62 * s, lineCap: .round))

            let dot: CGFloat = 84
            for (index, tint) in [devTint, hmlTint, prdTint].enumerated() {
                let centre = p(300 + CGFloat(index) * 112, 606)
                let rect = CGRect(
                    x: centre.x - dot * s / 2,
                    y: centre.y - dot * s / 2,
                    width: dot * s,
                    height: dot * s)
                context.fill(Path(ellipseIn: rect), with: .color(tint))
            }
        }
    }
}

// MARK: - Export

@MainActor
private func png(at pixels: CGFloat) -> Data {
    let renderer = ImageRenderer(content: AppIcon())
    renderer.scale = pixels / AppIcon.canvas
    renderer.isOpaque = false

    guard
        let image = renderer.cgImage,
        let representation = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else {
        fatalError("Could not render the icon at \(pixels)px")
    }
    return representation
}

/// Every slot macOS asks for, as (point size, scale).
private let slots: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

let repo = URL(fileURLWithPath: CommandLine.arguments.first.map {
    URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path
} ?? FileManager.default.currentDirectoryPath)

let iconSet = repo
    .appending(path: "hyperenv/Assets.xcassets/AppIcon.appiconset", directoryHint: .isDirectory)

try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

var entries: [[String: String]] = []
var rendered: [Int: Data] = [:]

for slot in slots {
    let pixels = slot.points * slot.scale
    let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"

    let data: Data
    if let cached = rendered[pixels] {
        data = cached
    } else {
        data = await png(at: CGFloat(pixels))
        rendered[pixels] = data
    }

    try data.write(to: iconSet.appending(path: name))
    entries.append([
        "filename": name,
        "idiom": "mac",
        "scale": "\(slot.scale)x",
        "size": "\(slot.points)x\(slot.points)",
    ])
    print("wrote \(name) (\(pixels)px)")
}

let contents: [String: Any] = [
    "images": entries,
    "info": ["author": "hyperenv", "version": 1],
]
let json = try JSONSerialization.data(
    withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconSet.appending(path: "Contents.json"))
print("wrote Contents.json")

// MARK: - Shared assets

// The accent colour is the icon's plate, so the app's selection highlight and
// its icon are literally the same colour rather than two values that drift.
// Light mode takes the midpoint of the plate gradient; dark mode lifts it,
// because the unmodified colour does not carry enough contrast against a dark
// window to read as a highlight.
func component(_ light: Double, _ dark: Double) -> (light: Double, dark: Double) {
    (light, dark)
}

let accentLight = (
    red: (0.286 + 0.435) / 2,
    green: (0.361 + 0.176) / 2,
    blue: (0.949 + 0.855) / 2
)
let accentDark = (
    red: min(accentLight.red + 0.10, 1),
    green: min(accentLight.green + 0.14, 1),
    blue: min(accentLight.blue + 0.05, 1)
)

func colorEntry(
    _ value: (red: Double, green: Double, blue: Double),
    appearances: [[String: String]]?
) -> [String: Any] {
    func hex(_ channel: Double) -> String {
        String(format: "0x%02X", Int((channel * 255).rounded()))
    }
    var entry: [String: Any] = [
        "idiom": "universal",
        "color": [
            "color-space": "srgb",
            "components": [
                "alpha": "1.000",
                "blue": hex(value.blue),
                "green": hex(value.green),
                "red": hex(value.red),
            ],
        ],
    ]
    if let appearances { entry["appearances"] = appearances }
    return entry
}

let accentSet = repo
    .appending(path: "hyperenv/Assets.xcassets/AccentColor.colorset", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: accentSet, withIntermediateDirectories: true)

let accentContents: [String: Any] = [
    "colors": [
        colorEntry(accentLight, appearances: nil),
        colorEntry(accentDark, appearances: [["appearance": "luminosity", "value": "dark"]]),
    ],
    "info": ["author": "hyperenv", "version": 1],
]
try JSONSerialization
    .data(withJSONObject: accentContents, options: [.prettyPrinted, .sortedKeys])
    .write(to: accentSet.appending(path: "Contents.json"))
print("wrote AccentColor.colorset")

// The same numbers the icon is drawn from, emitted as Swift so the interface
// and the icon cannot drift apart. Generated rather than hand-written for the
// same reason the accent colour is.
func swiftColor(_ name: String, _ value: (red: Double, green: Double, blue: Double)) -> String {
    func f(_ channel: Double) -> String { String(format: "%.3f", channel) }
    return """
        static let \(name) = Color(
            .sRGB, red: \(f(value.red)), green: \(f(value.green)), blue: \(f(value.blue)))
    """
}

let brandSource = """
//
//  Brand.swift
//  hyperenv
//
//  GENERATED by Scripts/generate-app-icon.swift — do not edit by hand.
//
//  The icon's palette, available to the interface. The plate gradient is the
//  app's identity; the three dots are the environment classes, and those are
//  declared in ProfileStyle where their meaning lives.
//
//  Identity colour is deliberately kept off anything that signals risk. The
//  question this app exists to answer is which environment is live, and a brand
//  colour spread across that signal would dilute it.
//

import SwiftUI

nonisolated enum Brand {
\(swiftColor("plateTop", (0.286, 0.361, 0.949)))
\(swiftColor("plateBottom", (0.435, 0.176, 0.855)))
\(swiftColor("accent", accentLight))

    // The three dots on the icon. ProfileStyle gives them their meaning; this
    // is only where the numbers live, so a badge and a dot cannot disagree.
\(swiftColor("development", (0.204, 0.780, 0.349)))
\(swiftColor("homologation", (1.000, 0.624, 0.039)))
\(swiftColor("production", (1.000, 0.271, 0.227)))

    /// The plate, as it appears on the icon.
    static let gradient = LinearGradient(
        colors: [plateTop, plateBottom],
        startPoint: .topLeading,
        endPoint: .bottomTrailing)

    /// A wash faint enough to sit behind text.
    static func tint(_ opacity: Double) -> LinearGradient {
        LinearGradient(
            colors: [plateTop.opacity(opacity), plateBottom.opacity(opacity)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }
}

"""

try brandSource.write(
    to: repo.appending(path: "hyperenv/Design/Brand.swift"),
    atomically: true,
    encoding: .utf8)
print("wrote hyperenv/Design/Brand.swift")

let assets = repo.appending(path: "assets", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let flat = repo.appending(path: "assets/icon-1024.png")
try (rendered[1024] ?? png(at: 1024)).write(to: flat)
print("wrote assets/icon-1024.png")

// iconutil wants its own layout and its own file names, so the .iconset is
// built and thrown away rather than kept in the tree beside the asset catalog.
let iconset = assets.appending(path: "HyperEnv.iconset", directoryHint: .isDirectory)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for slot in slots {
    let pixels = slot.points * slot.scale
    let data = try rendered[pixels] ?? png(at: CGFloat(pixels))
    rendered[pixels] = data
    let name = "icon_\(slot.points)x\(slot.points)\(slot.scale == 2 ? "@2x" : "").png"
    try data.write(to: iconset.appending(path: name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c", "icns",
    iconset.path(percentEncoded: false),
    "-o", assets.appending(path: "HyperEnv.icns").path(percentEncoded: false),
]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}
print("wrote assets/HyperEnv.icns")
