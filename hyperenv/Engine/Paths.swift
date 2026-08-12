//
//  Paths.swift
//  hyperenv
//

import Foundation

nonisolated enum Paths {

    /// The account's real home directory.
    ///
    /// Read from the password database rather than `NSHomeDirectory()`, which
    /// returns the container path whenever the app is sandboxed and would
    /// quietly send every write into `~/Library/Containers`.
    static var home: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory))
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    /// The account's login shell, from the password database. `$SHELL` is
    /// inherited and frequently lies about what the user actually logs into.
    static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }

    static var isZshLoginShell: Bool { loginShell.hasSuffix("/zsh") }

    // MARK: HyperEnv-owned locations

    static var configDirectory: URL { home.appending(path: ".config/hyperenv") }
    static var sessionScript: URL { configDirectory.appending(path: "session.zsh") }
    static var unsessionScript: URL { configDirectory.appending(path: "unsession.zsh") }
    static var journalDirectory: URL { configDirectory.appending(path: "journal") }
    static var currentJournal: URL { journalDirectory.appending(path: "current.json") }
    static var historyDirectory: URL { journalDirectory.appending(path: "history") }
    static var backupsDirectory: URL { configDirectory.appending(path: "backups") }
    static var lockFile: URL { configDirectory.appending(path: "lock") }

    // MARK: The user's files

    /// The injection target.
    ///
    /// `.zprofile` rather than `.zshenv` because `/etc/zprofile` runs
    /// `path_helper`, which reorders PATH — anything PATH-related written to
    /// `.zshenv` is silently undone before the user's shell is ready. It is
    /// also not `.zshenv` because that runs for *every* non-interactive shell,
    /// which would leak profile credentials into unrelated scripts and hooks.
    static var zprofile: URL { home.appending(path: ".zprofile") }

    // MARK: Display

    /// `$HOME`-relative form, for writing into shell scripts so the block stays
    /// valid if the home directory is ever remounted elsewhere.
    static func shellRelative(_ url: URL) -> String {
        let homePath = home.path(percentEncoded: false)
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix(homePath) else { return path }
        return "${HOME}" + path.dropFirst(homePath.count)
    }

    /// `~`-relative form for the interface.
    static func displayPath(_ url: URL) -> String {
        let homePath = home.path(percentEncoded: false)
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix(homePath) else { return path }
        return "~" + path.dropFirst(homePath.count)
    }
}
