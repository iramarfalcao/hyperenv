//
//  ProfileSheet.swift
//  hyperenv
//
//  Naming a profile and choosing its badge, for both creating and editing.
//

import SwiftUI

/// Asks for a profile's name and its badge.
///
/// The badge is the environment class, not a free colour, and that is
/// deliberate. The class decides whether applying asks for confirmation first
/// and which shape the menu bar shows, so a colour picked purely for looks would
/// quietly detach the production safeguard from the profile wearing production's
/// colour. Choosing the badge is therefore choosing the behaviour, and the sheet
/// says so for the one class where it matters.
struct ProfileSheet: View {
    let title: String
    var confirmLabel = "Create"
    @Binding var name: String
    @Binding var kind: ProfileKind
    var onCommit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text("A profile is one environment. Name it after what it points at.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("NAME")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)

                TextField(kind.rawValue, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit(commit)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("BADGE")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 10) {
                    ForEach(ProfileKind.creatable, id: \.self) { option in
                        swatch(for: option)
                    }
                    Spacer(minLength: 0)
                }

                // The swatches carry no text, so this one line names the chosen
                // badge. It stays because the badge is not only a colour: the
                // red one makes applying ask for confirmation first, and that
                // has to be visible at the moment it is picked.
                HStack(spacing: 6) {
                    Text(kind.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(kind.tint)
                    Text(kind == .prd
                         ? "— asks for confirmation before applying"
                         : "— \(kind.summary)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: commit)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { isFocused = true }
    }

    private func swatch(for option: ProfileKind) -> some View {
        let isSelected = option == kind

        return Button {
            // Keeps the name in step while it is still the default one, so
            // picking a badge before typing does the obvious thing.
            let wasDefault = trimmedName.isEmpty || trimmedName == kind.rawValue
            kind = option
            if wasDefault { name = option.rawValue }
        } label: {
            Circle()
                .fill(option.tint)
                .frame(width: 26, height: 26)
                .overlay {
                    // The selection is a ring around the swatch rather than a
                    // tick inside it, so the colour itself stays unobstructed.
                    Circle()
                        .strokeBorder(option.tint, lineWidth: 2)
                        .padding(-4)
                        .opacity(isSelected ? 1 : 0)
                }
                .shadow(
                    color: option.tint.opacity(isSelected ? 0.5 : 0),
                    radius: 5)
                .padding(4)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.16), value: isSelected)
        // The name is carried for VoiceOver and the tooltip rather than printed
        // beside the swatch: the badges are colour, and the line under them
        // already says which one is chosen.
        .help(option.label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(option.label)
    }

    private func commit() {
        guard !trimmedName.isEmpty else { return }
        name = trimmedName
        onCommit()
        dismiss()
    }
}
