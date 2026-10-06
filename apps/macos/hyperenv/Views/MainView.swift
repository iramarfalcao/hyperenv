//
//  MainView.swift
//  hyperenv
//
//  The window, as in the approved HyperEnv 2 mockup: a flat profile list on
//  the left, the selected profile's variables on the right, one main action
//  that is Apply or Undo, and a status bar that says what new terminals get.
//

import SwiftUI

struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TitleBar()
            HStack(spacing: 0) {
                Sidebar(model: model)
                    .frame(width: Tokens.sidebarWidth)
                Rectangle().fill(Tokens.line).frame(width: 1)
                VStack(spacing: 0) {
                    if model.selected != nil {
                        ProfileDetail(model: model)
                    } else {
                        EmptyDetail()
                    }
                    StatusBar(model: model)
                }
            }
        }
        .background(Tokens.surface)
        .foregroundStyle(Tokens.ink)
        .font(.ui(Tokens.sizeUi))
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 900, minHeight: 560)
    }
}

// MARK: - Title bar

/// Room for the window controls, and the wordmark in the middle — the
/// title itself is hidden, so this strip is the window's top edge.
private struct TitleBar: View {
    var body: some View {
        HStack(spacing: 6) {
            Text(">_").foregroundStyle(Tokens.accent)
            Text("hyper\(Text("env").foregroundStyle(Tokens.accent))")
        }
        .font(.mono(13, .semibold))
        .frame(maxWidth: .infinity)
        .frame(height: Tokens.titlebarHeight)
        .background(Tokens.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.line).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("HyperEnv")
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool
    @State private var naming = false
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Icon(name: .search).foregroundStyle(Tokens.muted)
                TextField("Search profiles", text: $model.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                Text("⌘K")
                    .font(.mono(Tokens.sizeCaption))
                    .foregroundStyle(Tokens.muted)
                    .padding(.horizontal, 5)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.radiusXs).stroke(Tokens.line))
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Tokens.radiusMd)
                .stroke(searchFocused ? Tokens.accent : Tokens.line))
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)
            .background {
                Button("") { searchFocused = true }.keyboardShortcut("k").hidden()
            }

            Text("PROFILES")
                .font(.ui(Tokens.sizeCaption, .semibold))
                .tracking(1)
                .foregroundStyle(Tokens.muted)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.visibleProfiles) { profile in
                        ProfileRow(profile: profile, current: profile.name == model.selectedName) {
                            model.selectedName = profile.name
                        }
                    }
                    if model.visibleProfiles.isEmpty {
                        Text(model.search.isEmpty ? "No profiles yet." : "No match.")
                            .foregroundStyle(Tokens.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 8)
            }

            Rectangle().fill(Tokens.line).frame(height: 1)

            Group {
                if naming {
                    TextField("profile-name", text: $newName)
                        .textFieldStyle(.plain)
                        .font(.mono(Tokens.sizeBody))
                        .focused($nameFocused)
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.radiusMd))
                        .overlay(RoundedRectangle(cornerRadius: Tokens.radiusMd).stroke(Tokens.accent))
                        .onSubmit {
                            model.createProfile(named: newName)
                            newName = ""
                            naming = false
                        }
                        .onExitCommand { naming = false; newName = "" }
                        .onAppear { nameFocused = true }
                } else {
                    Button { naming = true } label: {
                        HStack(spacing: 8) {
                            Icon(name: .add)
                            Text("New profile").font(.ui(Tokens.sizeUi, .medium))
                        }
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.radiusMd)
                        .stroke(Tokens.masked, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .keyboardShortcut("n")
                }
            }
            .padding(12)
        }
        .background(Tokens.sidebar)
    }
}

private struct ProfileRow: View {
    let profile: ProfileSummary
    let current: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 12) {
                Circle()
                    .fill(profile.isApplied ? Tokens.live : .clear)
                    .overlay(Circle().stroke(profile.isApplied ? .clear : Tokens.masked, lineWidth: 1.5))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.mono(Tokens.sizeBody, .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(profile.variableCount) variables\(profile.isApplied ? " · applied" : "")")
                        .font(.ui(Tokens.sizeSmall))
                        .foregroundStyle(Tokens.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 52)
            .background(
                current ? Tokens.surface : (hovering ? Tokens.lineSoft : .clear),
                in: RoundedRectangle(cornerRadius: Tokens.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Tokens.radiusMd).stroke(current ? Tokens.line : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}

// MARK: - Detail

private struct EmptyDetail: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("No profile selected")
                .font(.mono(Tokens.sizeHeading, .semibold))
            Text("A profile is a batch of variables. Apply it, and every new terminal starts with them; undo, and each one goes back to what it was.")
                .foregroundStyle(Tokens.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProfileDetail: View {
    @Bindable var model: AppModel
    @State private var renaming = false
    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let banner = model.banner {
                BannerView(banner: banner).padding(.bottom, 16)
            }
            VariableTable(model: model)
        }
        .padding(.horizontal, 32)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if renaming {
                    TextField("", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.mono(Tokens.sizeTitle, .semibold))
                        .onSubmit { model.renameSelected(to: draftName); renaming = false }
                        .onExitCommand { renaming = false }
                } else {
                    Text(model.selected?.name ?? "")
                        .font(.mono(Tokens.sizeTitle, .semibold))
                        .lineLimit(1)
                        .onTapGesture(count: 2) { draftName = model.selected?.name ?? ""; renaming = true }
                        .help("Double-click to rename")
                }
                Text("\(model.variables.count) variables · edited \(AppModel.shortTime(model.selected?.updatedAt ?? ""))")
                    .foregroundStyle(Tokens.muted)
            }
            Spacer()
            Menu {
                Button("Rename…") { draftName = model.selected?.name ?? ""; renaming = true }
                Button("Duplicate") { model.duplicateSelected() }
                Divider()
                Button("Import .env…") { model.importDotenv() }
                Button("Export .env…") { model.exportDotenv() }
            } label: {
                Icon(name: .export, size: 18)
                    .frame(width: 40, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: Tokens.radiusMd).stroke(Tokens.line))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions")

            IconButton(icon: .delete, label: "Delete profile", size: 40) { model.deleteSelected() }
                .disabled(model.isSelectedApplied || model.isBusy)

            if model.isSelectedApplied && !model.isSelectedDirty {
                ActionButton(title: model.isBusy ? "Working…" : "Undo", icon: .undo, primary: false) { model.undo() }
                    .disabled(model.isBusy)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            } else {
                ActionButton(title: model.isBusy ? "Applying…" : "Apply", icon: .apply, primary: true) { model.apply() }
                    .disabled(model.isBusy)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.top, 28)
        .padding(.bottom, 20)
    }
}

private struct BannerView: View {
    let banner: AppModel.Banner

    var body: some View {
        let (dot, background, text, message, detail): (Color, Color, Color, String, String) = switch banner {
        case .live(let m, let d): (Tokens.live, Tokens.liveBg, Tokens.liveText, m, d)
        case .pending(let m): (Tokens.pending, Tokens.pendingBg, Tokens.pendingText, m, "")
        case .error(let m): (Tokens.error, Tokens.pendingBg, Tokens.pendingText, m, "")
        case .info(let m): (Tokens.accent, Tokens.lineSoft, Tokens.ink, m, "")
        }
        HStack(spacing: 12) {
            Circle().fill(dot).frame(width: 8, height: 8)
            Text(message).lineLimit(2)
            Spacer(minLength: 8)
            if !detail.isEmpty {
                Text(detail).font(.mono(Tokens.sizeSmall)).lineLimit(1)
            }
        }
        .foregroundStyle(text)
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .background(background, in: RoundedRectangle(cornerRadius: Tokens.radiusMd))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Variables

private struct VariableTable: View {
    @Bindable var model: AppModel
    @State private var newVariable = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("NAME").frame(width: Tokens.keyColumn, alignment: .leading)
                Text("VALUE")
                Spacer()
            }
            .font(.ui(Tokens.sizeCaption, .semibold))
            .tracking(1)
            .foregroundStyle(Tokens.muted)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .overlay(alignment: .bottom) { Rectangle().fill(Tokens.line).frame(height: 1) }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.variables) { variable in
                        VariableRow(model: model, variable: variable)
                    }
                    HStack(spacing: 10) {
                        Icon(name: .add).foregroundStyle(Tokens.muted)
                        TextField("NEW_VARIABLE=value", text: $newVariable)
                            .textFieldStyle(.plain)
                            .font(.mono(Tokens.sizeBody))
                            .onSubmit { if model.setVariable(key: nil, text: newVariable) { newVariable = "" } }
                            .accessibilityLabel("New variable, as NAME=value")
                    }
                    .padding(.horizontal, 16)
                    .frame(height: Tokens.rowHeight)
                }
            }
        }
    }
}

private struct VariableRow: View {
    @Bindable var model: AppModel
    let variable: Variable
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var editing: Bool { model.editingKey == variable.key }
    private var masked: Bool { variable.isSecret && !model.isRevealed(variable.key) }

    var body: some View {
        HStack(spacing: 12) {
            Text(variable.key)
                .font(.mono(Tokens.sizeBody, .semibold))
                .foregroundStyle(variable.isEnabled ? Tokens.ink : Tokens.masked)
                .lineLimit(1)
                .frame(width: Tokens.keyColumn - 16, alignment: .leading)

            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.mono(Tokens.sizeBody))
                    .focused($focused)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(Tokens.surface, in: RoundedRectangle(cornerRadius: Tokens.radiusSm))
                    .overlay(RoundedRectangle(cornerRadius: Tokens.radiusSm).stroke(Tokens.line))
                    .onSubmit { model.setVariable(key: variable.key, text: draft) }
                    .onExitCommand { model.editingKey = nil }
                    .onAppear { draft = variable.value; focused = true }
                IconButton(icon: .confirm, label: "Save") { model.setVariable(key: variable.key, text: draft) }
                IconButton(icon: .close, label: "Cancel") { model.editingKey = nil }
            } else {
                Text(masked ? "••••••••••••••••" : variable.value)
                    .font(.mono(Tokens.sizeBody))
                    .tracking(masked ? 1.5 : 0)
                    .foregroundStyle(masked || !variable.isEnabled ? Tokens.masked : Tokens.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.editingKey = variable.key }
                    .help("Double-click to edit")
                    .textSelection(.disabled)

                HStack(spacing: 4) {
                    if variable.isSecret {
                        IconButton(icon: masked ? .reveal : .conceal, label: masked ? "Show value" : "Hide value") {
                            model.toggleReveal(variable.key)
                        }
                    }
                    IconButton(icon: .copy, label: "Copy value") { model.copy(variable) }
                    IconButton(icon: .delete, label: "Delete \(variable.key)") { model.deleteVariable(variable.key) }
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: editing ? 56 : Tokens.rowHeight)
        .background(editing ? Tokens.raised : .clear, in: RoundedRectangle(cornerRadius: editing ? Tokens.radiusMd : 0))
        .overlay {
            if editing { RoundedRectangle(cornerRadius: Tokens.radiusMd).stroke(Tokens.accent) }
        }
        .overlay(alignment: .bottom) {
            if !editing { Rectangle().fill(Tokens.lineSoft).frame(height: 1) }
        }
        .contextMenu {
            Button("Edit") { model.editingKey = variable.key }
            Button(variable.isEnabled ? "Turn Off" : "Turn On") { model.toggleEnabled(variable) }
            Button(variable.isSecret ? "Not a Secret" : "Mark as Secret") { model.toggleSecret(variable) }
            Divider()
            Button("Copy Value") { model.copy(variable) }
            Button("Delete") { model.deleteVariable(variable.key) }
        }
    }
}

// MARK: - Status bar

private struct StatusBar: View {
    let model: AppModel

    var body: some View {
        HStack {
            Text(model.statusLeft).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(model.statusRight)
        }
        .font(.mono(Tokens.sizeCaption))
        .foregroundStyle(Tokens.muted)
        .padding(.horizontal, 32)
        .frame(height: Tokens.statusbarHeight)
        .background(Tokens.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Tokens.line).frame(height: 1) }
    }
}

// MARK: - Controls

struct IconButton: View {
    let icon: Icon.Name
    let label: String
    var size: CGFloat = 32
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Icon(name: icon, size: size >= 40 ? 18 : 16)
                .foregroundStyle(size >= 40 ? Tokens.ink : Tokens.muted)
                .frame(width: size, height: size)
                .background(hovering ? Tokens.lineSoft : .clear, in: RoundedRectangle(cornerRadius: Tokens.radiusSm))
                .overlay {
                    if size >= 40 { RoundedRectangle(cornerRadius: Tokens.radiusMd).stroke(Tokens.line) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

struct ActionButton: View {
    let title: String
    let icon: Icon.Name
    let primary: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Icon(name: icon, size: 18)
                Text(title).font(.ui(Tokens.sizeUi, .semibold))
            }
            .padding(.horizontal, 18)
            .frame(height: 40)
            .foregroundStyle(primary ? Tokens.onAccent : Tokens.ink)
            .background(
                primary ? Tokens.accent.opacity(hovering ? 0.88 : 1) : Tokens.surface,
                in: RoundedRectangle(cornerRadius: Tokens.radiusMd))
            .overlay {
                if !primary { RoundedRectangle(cornerRadius: Tokens.radiusMd).stroke(Tokens.ink) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
    }
}
