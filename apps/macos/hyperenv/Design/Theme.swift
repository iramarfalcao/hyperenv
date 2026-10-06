//
//  Theme.swift
//  hyperenv
//
//  The pieces Tokens.swift (generated) builds on: appearance-aware colours,
//  the two embedded typefaces, and the interface icons from design/icons.
//

import AppKit
import CoreText
import SwiftUI

extension Color {
    /// A colour that follows the window's appearance, from two 0xRRGGBB values.
    init(light: UInt32, dark: UInt32) {
        func ns(_ v: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255,
                alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
}

enum Typeface {
    /// Registers the embedded Schibsted Grotesk and JetBrains Mono for this
    /// process only — nothing is installed on the system.
    static func register() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }
}

extension Font {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Tokens.fontUI, fixedSize: size).weight(weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Tokens.fontMono, fixedSize: size).weight(weight)
    }
}

/// One of HyperEnv's own interface icons (design/icons) — never an SF Symbol.
struct Icon: View {
    enum Name: String {
        case add, apply, close, conceal, confirm, copy, delete, drift, export, `import`
        case profile, reveal, search, secret, terminal, undo
    }

    let name: Name
    var size: CGFloat = 16

    var body: some View {
        Image("Icons/\(name.rawValue)")
            .renderingMode(.template)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
