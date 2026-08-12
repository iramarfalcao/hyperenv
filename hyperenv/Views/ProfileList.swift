//
//  ProfileList.swift
//  hyperenv
//

import SwiftData
import SwiftUI

struct ProfileList: View {
    let project: Project
    @Binding var selectedProfileID: UUID?
    let model: AppModel
    var onApply: (Profile) -> Void

    @Environment(\.modelContext) private var context
    @Namespace private var glass
    @State private var renaming: Profile?
    @State private var draftName = ""

    var body: some View {
        Group {
            if project.sortedProfiles.isEmpty {
                // A new project starts empty rather than being handed dev, hml
                // and prd it may not want, so this is the normal first screen —
                // not an error state. It offers the three as one click each,
                // which is why creating them automatically was not worth the
                // profiles people had to delete.
                ContentUnavailableView {
                    Label {
                        Text("No profiles yet")
                    } icon: {
                        Image(systemName: "square.stack.3d.up")
                            .foregroundStyle(Brand.gradient)
                    }
                } description: {
                    Text("A profile is one environment — its name, its variables, and the risk it carries.")
                } actions: {
                    if project.isDefault {
                        Text("The Default project holds the snapshot of your machine.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        // One control. The kind is picked from the menu rather
                        // than split across a second button, so the empty state
                        // says one thing.
                        Menu("Add Profile") {
                            ForEach(ProfileKind.creatable, id: \.self) { kind in
                                Button {
                                    addProfile(kind: kind)
                                } label: {
                                    Label(kind.label, systemImage: kind.symbol)
                                }
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .fixedSize()
                    }
                }
            } else {
                ScrollView {
                    // Grouping the cards lets adjacent glass surfaces blend and
                    // morph into one another instead of each rendering alone.
                    GlassEffectContainer(spacing: 12) {
                        VStack(spacing: 12) {
                            ForEach(project.sortedProfiles) { profile in
                                card(for: profile)
                                    .glassEffectID(profile.id, in: glass)
                                    .contextMenu { menu(for: profile) }
                            }
                        }
                    }
                    .padding(14)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(project.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(ProfileKind.creatable, id: \.self) { kind in
                        Button {
                            addProfile(kind: kind)
                        } label: {
                            Label(kind.label, systemImage: kind.symbol)
                        }
                    }
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
                .disabled(project.isDefault)
                .help(project.isDefault
                      ? "The Default project holds the snapshot of your machine."
                      : "Add a profile")
            }
        }
        .sheet(item: $renaming) { profile in
            NameSheet(title: "Rename Profile", name: $draftName) {
                profile.name = draftName
                try? context.save()
            }
        }
    }

    private var subtitle: String {
        let count = project.sortedProfiles.count
        return "\(count) profile\(count == 1 ? "" : "s")"
    }

    private func card(for profile: Profile) -> some View {
        let isApplied = model.isApplied(profile)
        let isSelected = profile.id == selectedProfileID

        return GlassCard(tint: isApplied ? profile.kind.tint : nil, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(profile.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    KindBadge(kind: profile.kind)

                    Spacer(minLength: 4)

                    if isApplied {
                        ActiveBadge(tint: profile.kind.tint)
                            // Grows out of the card rather than blinking in, so
                            // the eye is drawn to the profile that just went
                            // live instead of having to find it.
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }

                Divider().opacity(0.4)

                HStack(spacing: 6) {
                    Image(systemName: "number")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text("\(profile.enabledVariableCount) active")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    if profile.variables.count != profile.enabledVariableCount {
                        Text("of \(profile.variables.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }

                    Spacer(minLength: 8)

                    if profile.canBeApplied {
                        Button(isApplied ? "Applied" : "Apply") { onApply(profile) }
                            .buttonStyle(.glass)
                            .disabled(isApplied || model.isBusy)
                            .controlSize(.small)
                            .help(isApplied
                                  ? "This profile is already live"
                                  : "Point new terminals at \(profile.name)")
                    } else {
                        // Editing stays open; only the dangerous action is gated.
                        Label("Read-only", systemImage: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .help("A snapshot of your machine. Duplicate it to make an appliable profile.")
                    }
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isSelected ? profile.kind.tint.opacity(0.85) : .clear,
                    lineWidth: 2)
        }
        // A card that just became live lifts slightly. The scale is small on
        // purpose: this is the one card the user should notice, not a bounce.
        .scaleEffect(isApplied ? 1.015 : 1)
        .animation(.smooth(duration: 0.28), value: isApplied)
        .animation(.smooth(duration: 0.18), value: isSelected)
        // A card is a target, not decoration: hit-testing covers the padding
        // too, and it answers the keyboard and VoiceOver like any other control.
        .contentShape(.rect(cornerRadius: 14))
        .onTapGesture { selectedProfileID = profile.id }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel("\(profile.name), \(profile.kind.label)")
    }

    @ViewBuilder
    private func menu(for profile: Profile) -> some View {
        Button("Duplicate as Editable Profile") { duplicate(profile) }
        if !profile.isDefault {
            Button("Rename…") {
                draftName = profile.name
                renaming = profile
            }
            Divider()
            Button("Delete", role: .destructive) { delete(profile) }
        }
    }

    /// Moves the selection off the profile before deleting it, so the detail
    /// column is never resolving an object that is being torn down.
    private func delete(_ profile: Profile) {
        if selectedProfileID == profile.id {
            selectedProfileID = project.sortedProfiles.first { $0.id != profile.id }?.id
        }
        context.delete(profile)
        try? context.save()
    }

    private func addProfile(kind: ProfileKind) {
        let profile = Profile(
            name: kind.rawValue, kind: kind, sortIndex: project.profiles.count)
        profile.project = project
        context.insert(profile)
        try? context.save()
        selectedProfileID = profile.id
    }

    /// Copies a profile into a normal, appliable one. This is how the Default
    /// snapshot becomes a usable starting point.
    private func duplicate(_ profile: Profile) {
        let copy = Profile(
            name: "\(profile.name) copy",
            kind: profile.kind == .systemDefault ? .custom : profile.kind,
            sortIndex: project.profiles.count)
        copy.project = profile.project
        context.insert(copy)

        for variable in profile.sortedVariables {
            let duplicated = EnvVariable(
                key: variable.key,
                value: variable.value,
                isEnabled: variable.isEnabled,
                isSecret: variable.isSecret,
                note: variable.note,
                sortIndex: variable.sortIndex,
                origin: .authored)
            duplicated.profile = copy
            context.insert(duplicated)
        }

        try? context.save()
        selectedProfileID = copy.id
    }
}
