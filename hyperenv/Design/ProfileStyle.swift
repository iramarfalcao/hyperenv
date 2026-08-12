//
//  ProfileStyle.swift
//  hyperenv
//
//  The visual language for profiles.
//
//  Colour is doing real work here, not decoration: the question this app has to
//  answer at a glance is "which environment am I about to point my tools at",
//  and getting that wrong means running a migration against production.
//

import SwiftUI

extension ProfileKind {
    var tint: Color {
        switch self {
        // The exact values the icon's three dots are drawn with, so a badge in
        // the app and a dot on the icon are the same colour rather than two
        // that happen to look alike.
        case .dev: Brand.development
        case .hml: Brand.homologation
        case .prd: Brand.production
        // Custom carries no inherent risk, so it takes the app's own colour
        // rather than borrowing one that means something elsewhere.
        case .custom: Brand.accent
        case .systemDefault: .gray
        }
    }

    var symbol: String {
        switch self {
        case .dev: "hammer.fill"
        case .hml: "flask.fill"
        case .prd: "exclamationmark.triangle.fill"
        case .custom: "slider.horizontal.3"
        case .systemDefault: "desktopcomputer"
        }
    }

    var label: String {
        switch self {
        case .dev: "Development"
        case .hml: "Homologation"
        case .prd: "Production"
        case .custom: "Custom"
        case .systemDefault: "System snapshot"
        }
    }

    /// One line on what this class is for, shown while choosing a badge.
    var summary: String {
        switch self {
        case .dev: "Your own machine and throwaway data."
        case .hml: "A staging or homologation backend."
        case .prd: "Live systems and real customer data."
        case .custom: "Anything that is not one of the three."
        case .systemDefault: "A snapshot of this machine's environment."
        }
    }

    /// Fits inside a badge without wrapping.
    var shortLabel: String {
        switch self {
        case .dev: "DEV"
        case .hml: "HML"
        case .prd: "PROD"
        case .custom: "CUSTOM"
        case .systemDefault: "SNAPSHOT"
        }
    }

    /// Applying production is the one action here that can cause real damage,
    /// so it is the one action that asks first.
    var requiresConfirmation: Bool { self == .prd }

    static var creatable: [ProfileKind] { [.dev, .hml, .prd, .custom] }
}

// MARK: - Kind badge

/// The profile's environment class, stated in one small object.
///
/// Symbol *and* colour *and* text, deliberately redundant: colour alone fails
/// for roughly one man in twelve, and the thing colour is encoding here is
/// "am I about to point my tools at production".
struct KindBadge: View {
    let kind: ProfileKind
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbol)
                .font(.system(size: compact ? 8 : 9, weight: .bold))
            if !compact {
                Text(kind.shortLabel)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.4)
            }
        }
        .foregroundStyle(kind.tint)
        .padding(.horizontal, compact ? 5 : 6)
        .padding(.vertical, 3)
        .background(kind.tint.opacity(0.15), in: .capsule)
        .overlay {
            Capsule().strokeBorder(kind.tint.opacity(0.35), lineWidth: 0.5)
        }
        .accessibilityLabel(kind.label)
    }
}

/// Marks the one profile that is live right now.
struct ActiveBadge: View {
    let tint: Color

    var body: some View {
        Text("ACTIVE")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint, in: .capsule)
            .shadow(color: tint.opacity(0.4), radius: 3, y: 1)
    }
}

// MARK: - Glass surface

/// A card on the navigation layer.
///
/// Apple's guidance is that Liquid Glass belongs to the navigation layer and
/// must never be stacked on itself, so this is used for profile cards and the
/// status HUD — never for the variables table, which is content.
struct GlassCard<Content: View>: View {
    var tint: Color?
    var isInteractive = true
    var cornerRadius: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .glassEffect(
                .regular.tint(tint?.opacity(0.28)).interactive(isInteractive),
                in: .rect(cornerRadius: cornerRadius))
    }
}
