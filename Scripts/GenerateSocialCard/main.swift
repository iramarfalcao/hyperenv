//
//  GenerateSocialCard
//
//  Draws site/assets/og-image.png, the 1200×630 card shown when the site is
//  shared. Generated from the same palette as the icon, so the card cannot drift
//  from the product it is advertising.
//
//  1200×630 is not a suggestion: anything else is cropped, and every platform
//  crops differently. The important text is kept well inside the middle, because
//  some of them letterbox it further.
//

import AppKit
import SwiftUI

let width: CGFloat = 1200
let height: CGFloat = 630

private let plateTop = Color(.sRGB, red: 0.286, green: 0.361, blue: 0.949)
private let plateBottom = Color(.sRGB, red: 0.435, green: 0.176, blue: 0.855)
private let devTint = Color(.sRGB, red: 0.204, green: 0.780, blue: 0.349)
private let hmlTint = Color(.sRGB, red: 1.000, green: 0.624, blue: 0.039)
private let prdTint = Color(.sRGB, red: 1.000, green: 0.271, blue: 0.227)

struct Card: View {
    let iconPath: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(.sRGB, red: 0.055, green: 0.055, blue: 0.078),
                    Color(.sRGB, red: 0.098, green: 0.075, blue: 0.180),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing)

            // A wash of the plate colour, so the card reads as the same family
            // as the icon without hiding the text behind a full gradient.
            RadialGradient(
                colors: [plateTop.opacity(0.34), .clear],
                center: .init(x: 0.16, y: 0.12),
                startRadius: 0,
                endRadius: 760)

            HStack(alignment: .center, spacing: 56) {
                if let image = NSImage(contentsOfFile: iconPath) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 230, height: 230)
                        .shadow(color: plateBottom.opacity(0.55), radius: 40, y: 14)
                }

                VStack(alignment: .leading, spacing: 20) {
                    Text("HyperEnv")
                        .font(.system(size: 84, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Environment variables for macOS,\none project at a time.")
                        .font(.system(size: 33, weight: .regular))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineSpacing(6)

                    HStack(spacing: 13) {
                        ForEach([devTint, hmlTint, prdTint], id: \.self) { tint in
                            Circle()
                                .fill(tint)
                                .frame(width: 19, height: 19)
                        }
                        Text("dev · hml · prd")
                            .font(.system(size: 23, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .padding(.leading, 6)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 88)
        }
        .frame(width: width, height: height)
    }
}

@MainActor
func render(iconPath: String, to output: String) {
    let renderer = ImageRenderer(content: Card(iconPath: iconPath))
    renderer.scale = 1
    renderer.isOpaque = true

    // JPEG, not PNG. The card is flat colour and text at a fixed size, and a
    // lossless encode of it is roughly ten times larger for no visible gain —
    // paid on every share preview, by everyone.
    guard
        let image = renderer.cgImage,
        let data = NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.88])
    else {
        print("render failed")
        exit(1)
    }
    try? data.write(to: URL(fileURLWithPath: output))
    print("wrote \(output) (\(image.width)×\(image.height))")
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: <icon.png> <output.png>")
    exit(2)
}
render(iconPath: arguments[1], to: arguments[2])
