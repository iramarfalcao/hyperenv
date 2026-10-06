//
//  AppModel.swift
//  hyperenv
//
//  Everything the window and the menu bar show. Reads and edits go through
//  the core on the main actor — they only touch profiles.json and take a
//  couple of milliseconds. Apply, undo and the status check start the user's
//  login shell, so they run detached and come back here.
//

import AppKit
import Foundation
import Observation

@Observable
final class AppModel {

    enum Banner: Equatable {
        case live(String, detail: String)
        case pending(String)
        case error(String)
        case info(String)
    }

    private(set) var profiles: [ProfileSummary] = []
    private(set) var variables: [Variable] = []
    private(set) var status: Status?
    private(set) var isBusy = false
    var selectedName: String? { didSet { if oldValue != selectedName { selectionChanged() } } }
    var search = ""
    var revealed: Set<String> = []
    var editingKey: String?
    private(set) var notice: Banner?
    private var confirmDelete: String?

    /// Exported values of the applied profile, to tell "applied" from
    /// "applied, then edited".
    private var appliedExports: [String: String] = [:]

    init() {
        Typeface.register()
        migrateFromVersionOneIfNeeded()
        // The state without the drift probe is instant, so the window opens on
        // the applied profile; drift (which starts the shell) follows.
        if let quick = try? Core.run(["status", "--no-drift"], as: StatusWithExports.self) {
            status = quick.status
            appliedExports = quick.exports
        }
        reload()
        selectedName = status?.applied?.profileName ?? profiles.first?.name
        refreshStatus()
    }

    // MARK: Derived state

    var visibleProfiles: [ProfileSummary] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? profiles : profiles.filter { $0.name.lowercased().contains(q) }
    }

    var selected: ProfileSummary? { profiles.first { $0.name == selectedName } }
    var appliedName: String? { status?.applied?.profileName }

    var isSelectedApplied: Bool { selectedName != nil && selectedName == appliedName }

    /// Applied, but edited since: new terminals would still get the old values.
    var isSelectedDirty: Bool {
        guard isSelectedApplied else { return false }
        let current = Dictionary(
            variables.filter(\.isEnabled).map { ($0.key, $0.value) }, uniquingKeysWith: { $1 })
        return current != appliedExports
    }

    var banner: Banner? {
        if let notice { return notice }
        if isSelectedDirty { return .pending("Changed since it was applied. Apply again so new terminals get it.") }
        if isSelectedApplied, let applied = status?.applied {
            return .live(
                "Active in new terminals since \(Self.shortTime(applied.appliedAt)). Open ones keep what they had.",
                detail: targetLabel)
        }
        return nil
    }

    var targetLabel: String {
        guard let status else { return "" }
        return [status.shell, status.startupFile].compactMap(\.self).joined(separator: " · ")
    }

    var statusLeft: String {
        guard let applied = status?.applied else { return "nothing applied — original environment" }
        return "applied: \(applied.profileName) · \(targetLabel)"
    }

    var statusRight: String {
        guard let status, status.applied != nil else { return "" }
        switch status.drift.count {
        case 0: return "no drift"
        case 1: return "1 drift"
        case let n: return "\(n) drifts"
        }
    }

    // MARK: Loading

    func reload() {
        do {
            profiles = try Core.run(["profiles"])
            if let name = selectedName, profiles.contains(where: { $0.name == name }) {
                variables = try Core.run(["vars", name])
            } else {
                variables = []
            }
        } catch {
            notice = .error(error.localizedDescription)
        }
    }

    private func selectionChanged() {
        notice = nil
        confirmDelete = nil
        editingKey = nil
        reload()
    }

    /// `status` probes the login shell for drift, so it runs off the main actor.
    func refreshStatus() {
        Task {
            let result = await Task.detached { Result { try Core.run(["status"], as: StatusWithExports.self) } }.value
            switch result {
            case .success(let s):
                status = s.status
                appliedExports = s.exports
                profiles = (try? Core.run(["profiles"])) ?? profiles
            case .failure(let error):
                notice = .error(error.localizedDescription)
            }
        }
    }

    // MARK: Editing

    private func edit(_ args: [String]) -> Bool {
        notice = nil
        do {
            try Core.run(args)
            reload()
            return true
        } catch {
            notice = .error(error.localizedDescription)
            return false
        }
    }

    func createProfile(named name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, edit(["profile", "create", name]) else { return }
        search = ""
        selectedName = name
    }

    func renameSelected(to newName: String) {
        guard let old = selectedName else { return }
        let newName = newName.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != old, edit(["profile", "rename", old, newName]) else { return }
        selectedName = newName
    }

    func duplicateSelected() {
        guard let name = selectedName else { return }
        var copy = "\(name) copy"
        var n = 2
        while profiles.contains(where: { $0.name.caseInsensitiveCompare(copy) == .orderedSame }) {
            copy = "\(name) copy \(n)"; n += 1
        }
        if edit(["profile", "duplicate", name, copy]) { selectedName = copy }
    }

    /// The first press asks; the second deletes.
    func deleteSelected() {
        guard let name = selectedName else { return }
        guard confirmDelete == name else {
            confirmDelete = name
            notice = .pending("Press delete again to remove \"\(name)\" and its variables.")
            return
        }
        confirmDelete = nil
        if edit(["profile", "delete", name]) { selectedName = profiles.first?.name }
    }

    /// `NAME=value` for a new variable, or just the value for an existing key.
    @discardableResult
    func setVariable(key: String?, text: String) -> Bool {
        guard let profile = selectedName else { return false }
        let assignment: String
        if let key {
            assignment = "\(key)=\(text)"
        } else {
            guard text.contains("=") else {
                notice = .error("Write it as NAME=value.")
                return false
            }
            assignment = text.trimmingCharacters(in: .whitespaces)
        }
        let ok = edit(["var", "set", profile, assignment])
        if ok { editingKey = nil }
        return ok
    }

    func deleteVariable(_ key: String) {
        guard let profile = selectedName else { return }
        _ = edit(["var", "delete", profile, key])
    }

    func toggleEnabled(_ variable: Variable) {
        guard let profile = selectedName else { return }
        _ = edit(["var", variable.isEnabled ? "disable" : "enable", profile, variable.key])
    }

    func toggleSecret(_ variable: Variable) {
        guard let profile = selectedName else { return }
        _ = edit(["var", "set", profile, "\(variable.key)=\(variable.value)",
                  variable.isSecret ? "--no-secret" : "--secret"])
    }

    func toggleReveal(_ key: String) {
        let id = "\(selectedName ?? "")/\(key)"
        if revealed.remove(id) == nil { revealed.insert(id) }
    }

    func isRevealed(_ key: String) -> Bool { revealed.contains("\(selectedName ?? "")/\(key)") }

    func copy(_ variable: Variable) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(variable.value, forType: .string)
        notice = .info("\(variable.key) copied.")
    }

    func copyReloadCommand() {
        guard let command = status?.reloadCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        notice = .info("Copied: \(command)")
    }

    // MARK: .env files

    func importDotenv() {
        guard let profile = selectedName else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Choose a .env file to merge into \"\(profile)\""
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = edit(["import", profile, url.path])
        if notice == nil { notice = .info("Imported \(url.lastPathComponent).") }
    }

    func exportDotenv() {
        guard let profile = selectedName else { return }
        struct Exported: Decodable { let text: String }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ".env"
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let exported: Exported = try Core.run(["export", profile, "--dialect", "dotenv"])
            try exported.text.write(to: url, atomically: true, encoding: .utf8)
            notice = .info("Exported to \(url.lastPathComponent).")
        } catch {
            notice = .error(error.localizedDescription)
        }
    }

    // MARK: Apply and undo

    func apply(_ name: String? = nil) { runEngine(["apply", name ?? selectedName ?? ""]) }
    func undo() { runEngine(["unapply"]) }

    private func runEngine(_ args: [String]) {
        guard !isBusy, args.last != "" else { return }
        isBusy = true
        notice = nil
        Task {
            let result = await Task.detached { Result { try Core.run(args) } }.value
            isBusy = false
            if case .failure(let error) = result { notice = .error(error.localizedDescription) }
            reload()
            refreshStatus()
        }
    }

    // MARK: Migration from 1.x

    /// First launch of 2.0 with no profiles yet: bring in the 1.x profiles
    /// (its SwiftData store is only read, never changed).
    private func migrateFromVersionOneIfNeeded() {
        guard let existing: [ProfileSummary] = try? Core.run(["profiles"]), existing.isEmpty else { return }
        if let result: Migration = try? Core.run(["migrate"]), result.profiles > 0 {
            notice = .info("Brought \(result.profiles) profiles over from HyperEnv 1.")
        }
    }

    static func shortTime(_ rfc3339: String) -> String {
        let today = ISO8601DateFormatter.string(from: .now, timeZone: .gmt, formatOptions: [.withFullDate])
        let day = String(rfc3339.prefix(10))
        if day == today, rfc3339.count >= 16 {
            return String(rfc3339.dropFirst(11).prefix(5))
        }
        return day
    }
}

/// `status` with the applied values next to it.
private nonisolated struct StatusWithExports: Decodable {
    let status: Status
    let exports: [String: String]

    private struct Applied: Decodable { let exports: [String: String]? }
    private struct Wrapper: Decodable { let applied: Applied? }

    init(from decoder: any Decoder) throws {
        status = try Status(from: decoder)
        exports = (try? Wrapper(from: decoder))?.applied?.exports ?? [:]
    }
}
