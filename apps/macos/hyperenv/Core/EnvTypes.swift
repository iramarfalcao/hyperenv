//
//  EnvTypes.swift
//  hyperenv
//
//  Foundational value types for the environment engine.
//  Pure, Sendable, and free of I/O so they can cross actor boundaries
//  and be exercised by tests without touching the filesystem.
//

import Foundation

// MARK: - EnvKey

/// A validated environment variable name.
///
/// POSIX allows `[A-Za-z_][A-Za-z0-9_]*`. `env` can *report* names outside that
/// set, but `export` cannot *write* them — emitting one would produce a
/// `session.zsh` that fails to source, so invalid names are rejected at the type
/// level rather than being discovered at apply time.
nonisolated struct EnvKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    let rawValue: String

    init?(_ rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// ASCII-only on purpose: locale-aware character classes would accept names
    /// the shell cannot actually export.
    static func isValid(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        for (index, byte) in candidate.utf8.enumerated() {
            let isAlpha = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
            let isDigit = byte >= 48 && byte <= 57
            let isUnderscore = byte == 95
            if index == 0 {
                guard isAlpha || isUnderscore else { return false }
            } else {
                guard isAlpha || isDigit || isUnderscore else { return false }
            }
        }
        return true
    }

    var description: String { rawValue }

    static func < (lhs: EnvKey, rhs: EnvKey) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension EnvKey: Codable {
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let key = EnvKey(raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "'\(raw)' is not a valid environment variable name")
            )
        }
        self = key
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - EnvValue

/// An environment variable value. Any byte sequence is legal except NUL, which
/// terminates records in `env -0` output and cannot survive a round trip.
nonisolated struct EnvValue: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }

    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }
    var isEmpty: Bool { rawValue.isEmpty }
    var containsNewline: Bool { rawValue.contains(where: \.isNewline) }
}

// MARK: - EnvSet

/// An unordered set of variables that always *iterates* in sorted key order.
///
/// Determinism is not cosmetic here: exported `.env` files get committed to git,
/// and a nondeterministic key order turns every export into a noisy diff.
nonisolated struct EnvSet: Equatable, Sendable, Codable {
    private(set) var storage: [EnvKey: EnvValue]

    init(_ storage: [EnvKey: EnvValue] = [:]) { self.storage = storage }

    init(pairs: some Sequence<(EnvKey, EnvValue)>) {
        storage = [:]
        for (key, value) in pairs { storage[key] = value }
    }

    subscript(key: EnvKey) -> EnvValue? {
        get { storage[key] }
        set { storage[key] = newValue }
    }

    var keys: [EnvKey] { storage.keys.sorted() }
    var pairs: [(key: EnvKey, value: EnvValue)] { keys.map { ($0, storage[$0]!) } }
    var isEmpty: Bool { storage.isEmpty }
    var count: Int { storage.count }

    func contains(_ key: EnvKey) -> Bool { storage[key] != nil }

    /// Right-hand side wins, matching shell semantics where the last assignment
    /// takes effect.
    func merging(_ other: EnvSet) -> EnvSet {
        EnvSet(storage.merging(other.storage) { _, new in new })
    }

    func filter(_ isIncluded: (EnvKey, EnvValue) -> Bool) -> EnvSet {
        EnvSet(storage.filter { isIncluded($0.key, $0.value) })
    }
}

// MARK: - PriorState

/// What a variable looked like *before* HyperEnv touched it.
///
/// Deliberately not `EnvValue?`. An empty string and an unset variable are
/// different states in a shell, and un-apply has to reproduce the difference —
/// collapsing them into `nil` silently converts `export FOO=` into `unset FOO`.
nonisolated enum PriorState: Hashable, Sendable {
    case absent
    case present(EnvValue)

    var value: EnvValue? {
        switch self {
        case .absent: nil
        case .present(let value): value
        }
    }
}

extension PriorState: Codable {
    private enum CodingKeys: String, CodingKey { case state, value }
    private enum Tag: String, Codable { case absent, present }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Tag.self, forKey: .state) {
        case .absent:
            self = .absent
        case .present:
            self = .present(try container.decode(EnvValue.self, forKey: .value))
        }
    }

    /// Written with an explicit tag rather than a bare optional so the journal
    /// can never round-trip "set to empty" back as "unset".
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .absent:
            try container.encode(Tag.absent, forKey: .state)
        case .present(let value):
            try container.encode(Tag.present, forKey: .state)
            try container.encode(value, forKey: .value)
        }
    }
}

// MARK: - Targets and profiles

nonisolated enum ApplyTarget: String, Sendable, Codable, CaseIterable {
    /// The primary target: a guarded block in `~/.zprofile` sourcing our file.
    case zshStartupFile
    /// Opt-in secondary: `launchctl setenv`, session-scoped and cleared on logout.
    case launchd
}

nonisolated enum ProfileKind: String, Sendable, Codable, CaseIterable {
    case dev
    case hml
    case prd
    case custom
    /// The read-only snapshot of the machine's existing environment.
    case systemDefault = "default"
}

/// Where a variable came from, so the UI can distinguish authored configuration
/// from an observation of the machine.
nonisolated enum VariableOrigin: String, Sendable, Codable {
    case authored
    case imported
}

// MARK: - Errors

nonisolated enum HyperEnvError: Error, Sendable, Equatable {
    case invalidKey(String)
    case notUTF8(path: String, byteOffset: Int)
    case unbalancedMarkers(path: String, detail: String)
    case unsupportedLoginShell(path: String)
    case probeTimedOut(seconds: Int)
    case probeSentinelMissing
    case pathIsSymlinkOutsideHome(path: String, resolved: String)
    case lockUnavailable(path: String)
}

extension HyperEnvError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidKey(let key):
            "'\(key)' is not a valid environment variable name."
        case .notUTF8(let path, let offset):
            "\(path) is not valid UTF-8 (first bad byte at offset \(offset)). HyperEnv will not rewrite it, because decoding it lossily would destroy content."
        case .unbalancedMarkers(let path, let detail):
            "The HyperEnv block in \(path) is malformed (\(detail)). HyperEnv will not guess where it ends."
        case .unsupportedLoginShell(let path):
            "Your login shell is \(path). HyperEnv only knows how to write zsh syntax safely."
        case .probeTimedOut(let seconds):
            "Reading your shell environment timed out after \(seconds)s."
        case .probeSentinelMissing:
            "Could not find the output marker while reading your shell environment."
        case .pathIsSymlinkOutsideHome(let path, let resolved):
            "\(path) is a symlink to \(resolved), which is outside your home folder."
        case .lockUnavailable(let path):
            "Another HyperEnv operation is in progress (lock held at \(path))."
        }
    }
}
