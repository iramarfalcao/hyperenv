//
//  StatusViews.swift
//  hyperenv
//

import AppKit
import SwiftUI

// MARK: - Active profile status bar

/// The one element that must be readable at a glance.
///
/// Everything else in the app is about editing; this answers the only question
/// that carries risk — which environment new terminals are getting right now.
///
/// It is a real bottom bar rather than a floating capsule: a floating element
/// sits *on top of* the split view columns and hides the last row of whatever
/// the user is reading. A bar occupies its own space in the layout, so the
/// content above it is always fully visible.
struct ActiveProfileHUD: View {
    let model: AppModel
    @Binding var copied: Bool
    var onRevert: () -> Void

    private var isApplied: Bool { model.applied != nil }

    private var kind: ProfileKind {
        guard let name = model.applied?.profileName else { return .custom }
        return ProfileKind(rawValue: name.lowercased()) ?? .custom
    }

    private var tint: Color { isApplied ? kind.tint : .secondary }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 10) {
                StatusDot(tint: tint, isLit: isApplied, isPulsing: model.isBusy)

                summary

                Spacer(minLength: 16)

                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.8)
                        .frame(width: 16)
                }

                if isApplied { actions }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            // A wash instead of a solid fill: production has to be unmistakable
            // without turning the whole window into a warning label.
            .background(alignment: .leading) {
                if isApplied {
                    LinearGradient(
                        colors: [tint.opacity(0.20), tint.opacity(0.0)],
                        startPoint: .leading,
                        endPoint: .trailing)
                    .frame(maxWidth: 420, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(.bar)
        }
        .animation(.smooth(duration: 0.25), value: model.applied?.profileID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isApplied
            ? "Applied: \(model.applied?.displayPath ?? "")"
            : "Nothing applied")
    }

    @ViewBuilder
    private var summary: some View {
        if let applied = model.applied {
            HStack(spacing: 8) {
                Text(applied.displayPath)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Text(verbatim: "·")
                    .foregroundStyle(.tertiary)

                Text("\(applied.exports.count) variable\(applied.exports.count == 1 ? "" : "s") in new terminals")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: 8) {
                Text("Nothing applied")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(verbatim: "·")
                    .foregroundStyle(.tertiary)

                Text(model.isBusy
                     ? (model.statusMessage ?? "Working…")
                     : "Your own environment is untouched")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        // Applying cannot reach shells that are already open, so the command
        // that can is always one click away.
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.reloadCommand, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Label(
                copied ? "Copied" : "Copy reload command",
                systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? Color.green : Color.secondary)
        .help("Open terminals keep their old values until they run this: \(model.reloadCommand)")

        Divider().frame(height: 16)

        Button("Revert", action: onRevert)
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .disabled(model.isBusy)
            .help("Point new terminals back at your own environment")
    }
}

/// A small lamp. Lit when something is applied, breathing while work is in
/// flight — the only motion in the chrome, so it reads as activity.
private struct StatusDot: View {
    let tint: Color
    let isLit: Bool
    let isPulsing: Bool

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(isLit ? tint : Color.secondary.opacity(0.45))
            .frame(width: 8, height: 8)
            .shadow(color: isLit ? tint.opacity(0.6) : .clear, radius: 4)
            .opacity(isPulsing && pulse ? 0.35 : 1)
            .animation(
                isPulsing
                    ? .easeInOut(duration: 0.75).repeatForever(autoreverses: true)
                    : .default,
                value: pulse)
            .onChange(of: isPulsing, initial: true) { _, busy in pulse = busy }
            .accessibilityHidden(true)
    }
}

// MARK: - Banners

/// Shared shape for the two window-level notices, so they read as one family.
private struct Banner<Trailing: View>: View {
    let symbol: String
    let symbolTint: Color
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(symbolTint)
                .frame(width: 18)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                // Deliberately not .fixedSize(vertical:) — see the note in
                // VariableEditor's snapshot notice. It measures against a
                // near-zero width and returns a height that wrecks the window.
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            trailing
                .controlSize(.small)
                .padding(.top, 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(symbolTint.opacity(0.10), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(symbolTint.opacity(0.28), lineWidth: 1)
        }
    }
}

// MARK: - Setup

struct SetupBanner: View {
    let model: AppModel

    var body: some View {
        Banner(
            symbol: "wrench.and.screwdriver.fill",
            symbolTint: .orange,
            title: title,
            detail: detail
        ) {
            if case .malformed = model.hookStatus {
                // Refuse to guess where a damaged block ends; the user edits it.
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Paths.zprofile])
                }
                .buttonStyle(.bordered)
            } else {
                Button("Install Hook") {
                    Task { await model.installHook() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }
        }
    }

    private var title: String {
        switch model.hookStatus {
        case .notInstalled: "One-time setup needed"
        case .malformed: "The HyperEnv block needs attention"
        case .installed: ""
        }
    }

    private var detail: String {
        switch model.hookStatus {
        case .notInstalled:
            "HyperEnv adds three lines to \(Paths.displayPath(Paths.zprofile)) that load your applied variables. Your file is backed up first and never touched again."
        case .malformed(let reason):
            reason
        case .installed:
            ""
        }
    }
}

// MARK: - Drift

struct DriftBanner: View {
    let drift: [DriftKind]
    let model: AppModel

    var body: some View {
        Banner(
            symbol: "exclamationmark.triangle.fill",
            symbolTint: .yellow,
            title: "Your environment does not match what HyperEnv applied",
            detail: drift.map(describe).joined(separator: "\n")
        ) {
            Button("Re-check") { Task { await model.checkDrift() } }
                .buttonStyle(.bordered)
        }
    }

    private func describe(_ kind: DriftKind) -> String {
        switch kind {
        case .managedFileEdited:
            "session.zsh was edited by hand. Applying again will overwrite those changes."
        case .markerBlockMissing:
            "The block was removed from \(Paths.displayPath(Paths.zprofile)). Apply again to reinstall it."
        case .dotfileChangedOutsideBlock:
            "Your dotfile changed outside the HyperEnv block."
        case .launchdSessionExpired:
            "The login session restarted, so launchd variables were cleared."
        case .semantic(let details):
            // The failure a checksum cannot see: something assigned the same
            // variable after our block and quietly won.
            details
                .sorted { $0.key < $1.key }
                .prefix(4)
                .map { key, detail in
                    switch detail {
                    case .missing:
                        "\(key) is missing from your shell."
                    case .shadowed(_, let actual):
                        "\(key) was overridden after our block (now \"\(actual)\")."
                    }
                }
                .joined(separator: " ")
        }
    }
}
