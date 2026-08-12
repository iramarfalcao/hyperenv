//
//  VariableEditor.swift
//  hyperenv
//

import SwiftData
import SwiftUI

struct VariableEditor: View {
    @Bindable var profile: Profile
    let model: AppModel

    @Environment(\.modelContext) private var context
    @State private var transfer = DotenvTransfer()
    @State private var search = ""

    /// Case-insensitive over both halves of the pair — people look for a value
    /// they half-remember at least as often as for a name.
    private var visibleVariables: [EnvVariable] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return profile.sortedVariables }
        return profile.sortedVariables.filter {
            $0.key.lowercased().contains(query) || $0.value.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if profile.isDefault { snapshotNotice }

            // Content layer: deliberately plain. Liquid Glass is for the
            // navigation layer, and stacking glass on glass is explicitly
            // against the material's rules.
            if profile.variables.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("No variables")
                    } icon: {
                        Image(systemName: "text.append")
                            .foregroundStyle(Brand.gradient)
                    }
                } description: {
                    Text("Add one by hand, or import an existing .env file.")
                } actions: {
                    HStack {
                        Button("Add Variable", action: addVariable)
                            .buttonStyle(.glassProminent)
                        Button("Import .env") { transfer.beginImport() }
                            .buttonStyle(.glass)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    columnHeader

                    List {
                        ForEach(visibleVariables) { variable in
                            VariableRow(variable: variable, onDelete: { delete(variable) })
                                .listRowInsets(.init(top: 0, leading: 10, bottom: 0, trailing: 10))
                        }
                    }
                    .listStyle(.inset)
                    // No alternating row backgrounds: they are drawn for the
                    // full height of the table, so a short profile renders a
                    // dozen empty striped rows below the real ones that read as
                    // content which failed to load.
                    .overlay {
                        if visibleVariables.isEmpty {
                            ContentUnavailableView.search(text: search)
                        }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Filter variables")
        .navigationTitle(profile.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button("Add Variable", systemImage: "plus", action: addVariable)
            }
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Menu {
                    // Scope first, then dialect. A snapshot profile has nothing
                    // switched on, so without "All Variables" its only export is
                    // an empty file — which is what this menu used to produce.
                    ForEach(DotenvTransfer.Scope.allCases) { scope in
                        Section(scope.label) {
                            ForEach(DotenvDialect.allCases) { dialect in
                                Button {
                                    transfer.export(
                                        profile: profile, dialect: dialect, scope: scope)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(dialect.displayName)
                                        Text(dialect.summary)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    Label("Export .env", systemImage: "square.and.arrow.up")
                }
                .disabled(profile.variables.isEmpty)
                .help(profile.enabledVariableCount == 0
                      ? "Nothing in \(profile.name) is switched on — use All Variables"
                      : "Write these variables to a .env file")
            }
            ToolbarItem {
                Button("Import .env", systemImage: "square.and.arrow.down") {
                    transfer.beginImport()
                }
            }
        }
        .sheet(item: $transfer.pendingImport) { pending in
            ImportPreviewSheet(pending: pending) { entries in
                apply(imported: entries)
            }
        }
        .alert(
            transfer.alertTitle,
            isPresented: $transfer.showsAlert
        ) {
            if let confirm = transfer.pendingOverwrite {
                Button("Overwrite", role: .destructive) { transfer.commitOverwrite(confirm) }
                Button("Cancel", role: .cancel) { transfer.pendingOverwrite = nil }
            } else {
                Button("OK") {}
            }
        } message: {
            Text(transfer.alertMessage)
        }
    }

    private var subtitle: String {
        let active = profile.enabledVariableCount
        let total = profile.variables.count
        return total == active
            ? "\(active) variable\(active == 1 ? "" : "s")"
            : "\(active) of \(total) active"
    }

    /// Names the three columns the rows are already using, so the toggle and
    /// the monospaced name column stop looking like an unlabelled grid.
    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text("ON")
                .frame(width: 28, alignment: .leading)
            Text("NAME")
                .frame(width: 210, alignment: .leading)
            Text("VALUE")
            Spacer()
        }
        .font(.system(size: 9, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.22))
        .overlay(alignment: .bottom) { Divider() }
    }

    private var snapshotNotice: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("This is a snapshot of your machine, not a configuration.")
                    .font(.system(size: 12, weight: .medium))
                // No .fixedSize(vertical:) here, however tempting it looks for
                // stopping truncation. It asks for the text's *ideal* height,
                // and during the split view's measuring pass the proposed width
                // is nearly zero — so the text wraps into a column some 2000pt
                // tall and drags the entire window's layout with it. Text in a
                // width-bounded stack already wraps without help.
                Text("You can edit it, but it cannot be applied — re-exporting a whole stale environment would freeze your shell. Duplicate it to make an appliable profile.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func addVariable() {
        let variable = EnvVariable(
            key: "", value: "", sortIndex: profile.variables.count)
        variable.profile = profile
        context.insert(variable)
        try? context.save()
    }

    private func delete(_ variable: EnvVariable) {
        context.delete(variable)
        try? context.save()
    }

    private func apply(imported entries: [DotenvEntry]) {
        var existing: [String: EnvVariable] = [:]
        for variable in profile.variables { existing[variable.key] = variable }

        for entry in entries {
            if let match = existing[entry.key.rawValue] {
                match.value = entry.value.rawValue
            } else {
                let variable = EnvVariable(
                    key: entry.key.rawValue,
                    value: entry.value.rawValue,
                    sortIndex: profile.variables.count,
                    origin: .imported)
                variable.profile = profile
                context.insert(variable)
            }
        }
        try? context.save()
        transfer.pendingImport = nil
    }
}

// MARK: - Row

/// Internal rather than private so `Tests/LayoutChecks` can measure the width
/// one row demands. A row that asks for more than the window has is the bug
/// this type is most likely to reintroduce.
struct VariableRow: View {
    @Bindable var variable: EnvVariable
    var onDelete: () -> Void

    @State private var revealSecret = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $variable.isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 28, alignment: .leading)
                .help(variable.isEnabled ? "Included when applied" : "Ignored when applied")

            HStack(spacing: 4) {
                TextField("NAME", text: $variable.key)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(keyColor)
                    .lineLimit(1)
                    // Same reasoning as the value field: a long name must not
                    // widen the row either.
                    .frame(minWidth: 40, idealWidth: 160, maxWidth: .infinity, alignment: .leading)
                    .help(variable.key.isEmpty || variable.isKeyValid
                          ? ""
                          : "Not a valid variable name. It will be skipped when applying.")

                // A name the shell cannot export is silently dropped at apply
                // time, so it is called out where it is typed instead.
                if !variable.key.isEmpty && !variable.isKeyValid {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                        .help("Not a valid variable name. It will be skipped when applying.")
                }
            }
            .frame(width: 210, alignment: .leading)

            // A plain text field reports an ideal width that fits its whole
            // value. PATH in the snapshot profile is 400+ characters, which asks
            // for roughly 3000pt in a column a fifth that wide — enough to push
            // every other column's content off screen and leave the window
            // looking empty. Capping the ideal width stops the value's length
            // from reaching the layout at all.
            Group {
                if variable.isSecret && !revealSecret {
                    SecureField("value", text: $variable.value)
                } else {
                    TextField("value", text: $variable.value)
                        .foregroundStyle(variable.isEnabled ? .primary : .secondary)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .frame(minWidth: 80, idealWidth: 240, maxWidth: .infinity, alignment: .leading)

            // Seeded variables carry the reason they were classified the way
            // they were, so a switched-off row never looks arbitrary.
            if let bucket = variable.bucket, !bucket.isImportable {
                Text(bucketLabel(bucket))
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
                    .foregroundStyle(.secondary)
                    .help(bucket.explanation)
            }

            if let note = variable.note {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help(note)
            }

            Button {
                if variable.isSecret { revealSecret.toggle() } else { variable.isSecret = true }
            } label: {
                Image(systemName: variable.isSecret
                      ? (revealSecret ? "eye.fill" : "eye.slash.fill")
                      : "eye")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(variable.isSecret ? Color.accentColor : .secondary)
            .help(variable.isSecret ? "Toggle visibility" : "Mask this value")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isHovering ? Color.red : .secondary)
            .help("Delete this variable")
        }
        .padding(.vertical, 4)
        .opacity(variable.isEnabled ? 1 : 0.62)
        .onHover { isHovering = $0 }
    }

    private var keyColor: Color {
        if variable.key.isEmpty { return .primary }
        return variable.isKeyValid ? .primary : .red
    }

    private func bucketLabel(_ bucket: SeedBucket) -> String {
        switch bucket {
        case .user: "USER"
        case .derived: "TOOLING"
        case .session: "SESSION"
        case .pathLike: "PATH"
        case .cosmetic: "TERMINAL"
        case .rejected: "UNSAFE"
        }
    }
}
