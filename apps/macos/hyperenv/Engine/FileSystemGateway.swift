//
//  FileSystemGateway.swift
//  hyperenv
//
//  All filesystem side effects, behind a protocol so the engine can be driven
//  by an in-memory fake in tests.
//

import CryptoKit
import Foundation

nonisolated protocol FileSystemGateway: Sendable {
    func exists(_ url: URL) -> Bool
    func readData(_ url: URL) throws -> Data
    func readText(_ url: URL) throws -> String
    func write(_ data: Data, to url: URL, permissions: Int16?) throws
    func createDirectory(_ url: URL) throws
    func remove(_ url: URL) throws
    func contentsOfDirectory(_ url: URL) throws -> [URL]
    func resolvingSymlink(_ url: URL) throws -> URL
    func modificationDate(_ url: URL) -> Date?
}

// The project compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so
// these helpers must opt out explicitly — otherwise the engine actor cannot
// call them.
extension FileSystemGateway {
    nonisolated func write(_ text: String, to url: URL, permissions: Int16? = 0o600) throws {
        try write(Data(text.utf8), to: url, permissions: permissions)
    }

    nonisolated func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func readTextIfExists(_ url: URL) throws -> String? {
        exists(url) ? try readText(url) : nil
    }
}

// MARK: - Real implementation

nonisolated struct RealFileSystem: FileSystemGateway {

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    func readData(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// Refuses rather than decoding lossily.
    ///
    /// `String(decoding:as:)` silently substitutes U+FFFD for invalid bytes,
    /// and writing that back would permanently destroy content in a file the
    /// user did not expect us to rewrite.
    func readText(_ url: URL) throws -> String {
        let data = try readData(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HyperEnvError.notUTF8(
                path: Paths.displayPath(url),
                byteOffset: Self.firstInvalidUTF8Offset(in: data) ?? 0
            )
        }
        return text
    }

    /// Writes via a temporary file in the same directory followed by an atomic
    /// rename, so a crash can never leave a half-written `session.zsh` that
    /// breaks every new shell.
    func write(_ data: Data, to url: URL, permissions: Int16?) throws {
        let directory = url.deletingLastPathComponent()
        try createDirectory(directory)

        let temporary = directory.appending(path: ".hyperenv-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)

        if let permissions {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: permissions)],
                ofItemAtPath: temporary.path(percentEncoded: false))
        } else if exists(url),
                  let existing = try? FileManager.default.attributesOfItem(
                      atPath: url.path(percentEncoded: false)),
                  let mode = existing[.posixPermissions] {
            // Preserve whatever the user's own file had.
            try FileManager.default.setAttributes(
                [.posixPermissions: mode],
                ofItemAtPath: temporary.path(percentEncoded: false))
        }

        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove(_ url: URL) throws {
        guard exists(url) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func contentsOfDirectory(_ url: URL) throws -> [URL] {
        guard exists(url) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil)
    }

    /// Follows symlinks before writing.
    ///
    /// A `~/.zprofile` managed by chezmoi, stow or yadm is a symlink into a
    /// dotfiles repository. `replaceItemAt` on the link would replace it with a
    /// regular file and silently detach the user's repo, so the real target is
    /// resolved and written instead.
    func resolvingSymlink(_ url: URL) throws -> URL {
        let path = url.path(percentEncoded: false)
        guard exists(url) else { return url }

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else { return url }

        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: path)
        let resolved = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : url.deletingLastPathComponent().appending(path: destination)

        return resolved.standardizedFileURL
    }

    func modificationDate(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false))[.modificationDate] as? Date
    }

    // MARK: UTF-8 validation

    /// Locates the first byte that cannot begin or continue a valid sequence,
    /// so the error can point the user at the exact spot.
    static func firstInvalidUTF8Offset(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            let width: Int

            switch byte {
            case 0x00...0x7F: width = 1
            case 0xC2...0xDF: width = 2
            case 0xE0...0xEF: width = 3
            case 0xF0...0xF4: width = 4
            default: return index
            }

            guard index + width <= bytes.count else { return index }
            for offset in 1..<width where !(0x80...0xBF).contains(bytes[index + offset]) {
                return index
            }
            index += width
        }
        return nil
    }
}

// MARK: - Advisory locking

/// Serialises applies across processes and windows.
nonisolated struct FileLock {
    private let descriptor: Int32

    init(path: URL) throws {
        let directory = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        descriptor = open(path.path(percentEncoded: false), O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw HyperEnvError.lockUnavailable(path: Paths.displayPath(path))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw HyperEnvError.lockUnavailable(path: Paths.displayPath(path))
        }
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    static func withLock<T>(at path: URL, _ work: () throws -> T) throws -> T {
        let lock = try FileLock(path: path)
        defer { lock.release() }
        return try work()
    }
}
