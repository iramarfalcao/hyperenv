//
//  DotenvCodec.swift
//  hyperenv
//
//  Reading and writing `.env` files.
//
//  There is no single correct `.env` dialect. `docker --env-file` performs no
//  quote removal at all — it takes the raw bytes after `=` — so a value quoted
//  for shell compatibility arrives in Docker with literal quotes around it.
//  The dialect is therefore an explicit choice, never a guess.
//

import Foundation

// MARK: - Dialect

nonisolated enum DotenvDialect: String, Sendable, CaseIterable, Codable, Identifiable {
    /// Single-quoted. Safe to `source` from a shell.
    case posixShell
    /// Double-quoted with escapes. What most dotenv libraries expect.
    case dotenv
    /// Raw bytes after `=`. No quoting, no newlines.
    case docker

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .posixShell: "POSIX shell"
        case .dotenv: "dotenv (quoted)"
        case .docker: "docker --env-file"
        }
    }

    var summary: String {
        switch self {
        case .posixShell: "Single-quoted and safe to source. Preserves newlines."
        case .dotenv: "Double-quoted with escapes. Newlines become \\n."
        case .docker: "Raw values, no quoting. Newlines are not supported."
        }
    }
}

// MARK: - Results

nonisolated struct DotenvEntry: Sendable, Equatable {
    let key: EnvKey
    let value: EnvValue
    /// 1-based, so it can be shown directly in a diagnostics list.
    let line: Int
}

nonisolated struct DotenvDiagnostic: Sendable, Equatable, Identifiable {
    enum Severity: String, Sendable, Equatable {
        case warning
        case error
    }

    let id = UUID()
    let severity: Severity
    let line: Int
    let message: String

    static func == (lhs: DotenvDiagnostic, rhs: DotenvDiagnostic) -> Bool {
        lhs.severity == rhs.severity && lhs.line == rhs.line && lhs.message == rhs.message
    }
}

nonisolated struct DotenvDecodeResult: Sendable {
    let entries: [DotenvEntry]
    let diagnostics: [DotenvDiagnostic]

    var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }

    /// Duplicates resolved (last wins), ready to import.
    var envSet: EnvSet {
        var set = EnvSet()
        for entry in entries { set[entry.key] = entry.value }
        return set
    }
}

// MARK: - Codec

nonisolated enum DotenvCodec {

    struct Limits: Sendable {
        var maxBytes = 5 * 1024 * 1024
        var maxValueBytes = 64 * 1024
        var maxEntries = 5_000
        static let `default` = Limits()
    }

    // MARK: Encode

    /// Renders variables to `.env` text.
    ///
    /// Keys are emitted in sorted order. This file gets committed to git, and a
    /// nondeterministic ordering would make every export produce a meaningless
    /// diff.
    static func encode(
        _ variables: EnvSet,
        dialect: DotenvDialect,
        headerComment: [String] = [],
        includeExportPrefix: Bool = false
    ) -> (text: String, diagnostics: [DotenvDiagnostic]) {
        var lines = headerComment.map { "# \($0)" }
        if !lines.isEmpty { lines.append("") }

        var diagnostics: [DotenvDiagnostic] = []
        let prefix = includeExportPrefix ? "export " : ""

        for (key, value) in variables.pairs {
            let rendered: String
            switch dialect {
            case .posixShell:
                rendered = ShellQuoting.singleQuote(value.rawValue)
            case .dotenv:
                rendered = ShellQuoting.doubleQuote(value.rawValue)
            case .docker:
                if value.containsNewline {
                    diagnostics.append(.init(
                        severity: .error, line: 0,
                        message: "\(key) contains a newline, which docker --env-file cannot represent. It was skipped."))
                    continue
                }
                rendered = value.rawValue
            }
            lines.append("\(prefix)\(key.rawValue)=\(rendered)")
        }

        return (lines.joined(separator: "\n") + "\n", diagnostics)
    }

    // MARK: Decode

    /// Parses `.env` text, returning everything it could read *plus* everything
    /// it objected to. A malformed line is rejected on its own; it never aborts
    /// the rest of the file.
    static func decode(_ raw: String, limits: Limits = .default) -> DotenvDecodeResult {
        var entries: [DotenvEntry] = []
        var diagnostics: [DotenvDiagnostic] = []

        if raw.utf8.count > limits.maxBytes {
            return .init(entries: [], diagnostics: [
                .init(severity: .error, line: 0,
                      message: "File is larger than \(limits.maxBytes / 1_048_576) MB.")
            ])
        }

        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")

        let chars = Array(text)
        var index = 0
        var line = 1

        func skipInlineWhitespace() {
            while index < chars.count, chars[index] == " " || chars[index] == "\t" { index += 1 }
        }
        func skipToEndOfLine() {
            while index < chars.count, chars[index] != "\n" { index += 1 }
        }

        while index < chars.count {
            skipInlineWhitespace()
            guard index < chars.count else { break }

            if chars[index] == "\n" { index += 1; line += 1; continue }
            if chars[index] == "#" { skipToEndOfLine(); continue }

            let entryLine = line

            // Optional `export ` prefix — accepted because shell-style .env
            // files are common, though many dotenv parsers reject it.
            if matches("export", at: index, in: chars),
               index + 6 < chars.count,
               chars[index + 6] == " " || chars[index + 6] == "\t" {
                index += 6
                skipInlineWhitespace()
            }

            // Key
            var key = ""
            while index < chars.count,
                  chars[index] != "=", chars[index] != "\n",
                  chars[index] != " ", chars[index] != "\t" {
                key.append(chars[index])
                index += 1
            }

            var sawSpaceBeforeEquals = false
            if index < chars.count, chars[index] == " " || chars[index] == "\t" {
                sawSpaceBeforeEquals = true
                skipInlineWhitespace()
            }

            guard index < chars.count, chars[index] == "=" else {
                diagnostics.append(.init(severity: .error, line: entryLine,
                                         message: "No '=' found. Line skipped."))
                skipToEndOfLine()
                continue
            }
            index += 1  // consume '='

            guard let envKey = EnvKey(key) else {
                diagnostics.append(.init(
                    severity: .error, line: entryLine,
                    message: key.isEmpty
                        ? "Missing variable name before '='. Line skipped."
                        : "'\(key)' is not a valid variable name. Line skipped."))
                skipToEndOfLine()
                continue
            }

            var sawSpaceAfterEquals = false
            if index < chars.count, chars[index] == " " || chars[index] == "\t" {
                sawSpaceAfterEquals = true
                skipInlineWhitespace()
            }
            if sawSpaceBeforeEquals || sawSpaceAfterEquals {
                diagnostics.append(.init(
                    severity: .warning, line: entryLine,
                    message: "Whitespace around '='. A shell would read this as a command, not an assignment."))
            }

            // Value
            let startsQuoted = index < chars.count && (chars[index] == "'" || chars[index] == "\"")
            var value = ""

            if startsQuoted {
                // Shell word semantics: adjacent quoted and bare runs
                // concatenate, which is what lets HyperEnv's own single-quoted
                // output round-trip ('it'\''s' -> it's).
                runs: while index < chars.count, chars[index] != "\n" {
                    switch chars[index] {
                    case "'":
                        index += 1
                        var closed = false
                        while index < chars.count {
                            if chars[index] == "'" { index += 1; closed = true; break }
                            if chars[index] == "\n" { line += 1 }
                            value.append(chars[index]); index += 1
                        }
                        if !closed {
                            diagnostics.append(.init(severity: .error, line: entryLine,
                                                     message: "Unterminated single quote. Line skipped."))
                            break runs
                        }
                    case "\"":
                        index += 1
                        var closed = false
                        while index < chars.count {
                            if chars[index] == "\"" { index += 1; closed = true; break }
                            if chars[index] == "\\", index + 1 < chars.count {
                                index += 1
                                value.append(unescape(chars[index]))
                                index += 1
                                continue
                            }
                            if chars[index] == "\n" { line += 1 }
                            value.append(chars[index]); index += 1
                        }
                        if !closed {
                            diagnostics.append(.init(severity: .error, line: entryLine,
                                                     message: "Unterminated double quote. Line skipped."))
                            break runs
                        }
                    case " ", "\t":
                        break runs
                    case "\\":
                        index += 1
                        if index < chars.count { value.append(chars[index]); index += 1 }
                    default:
                        value.append(chars[index]); index += 1
                    }
                }
                skipToEndOfLine()
            } else {
                // Bare value: dotenv semantics. Take the rest of the line, then
                // strip a trailing ` # comment`. A '#' *not* preceded by
                // whitespace is part of the value (URL fragments, colour hexes).
                var bare = ""
                while index < chars.count, chars[index] != "\n" {
                    bare.append(chars[index]); index += 1
                }
                if let hash = bare.range(of: " #") ?? bare.range(of: "\t#") {
                    bare = String(bare[bare.startIndex..<hash.lowerBound])
                }
                value = bare.trimmingCharacters(in: .whitespaces)
            }

            if value.utf8.count > limits.maxValueBytes {
                diagnostics.append(.init(
                    severity: .error, line: entryLine,
                    message: "Value for \(envKey) exceeds \(limits.maxValueBytes / 1024) KB. Skipped."))
                continue
            }

            entries.append(.init(key: envKey, value: EnvValue(value), line: entryLine))

            if entries.count > limits.maxEntries {
                diagnostics.append(.init(severity: .error, line: entryLine,
                                         message: "More than \(limits.maxEntries) entries. Stopped."))
                break
            }
        }

        diagnostics.append(contentsOf: duplicateWarnings(in: entries))
        return .init(entries: entries, diagnostics: diagnostics)
    }

    // MARK: Helpers

    private static func matches(_ word: String, at index: Int, in chars: [Character]) -> Bool {
        let letters = Array(word)
        guard index + letters.count <= chars.count else { return false }
        for offset in letters.indices where chars[index + offset] != letters[offset] { return false }
        return true
    }

    private static func unescape(_ character: Character) -> String {
        switch character {
        case "n": "\n"
        case "r": "\r"
        case "t": "\t"
        case "\\": "\\"
        case "\"": "\""
        case "$": "$"
        // Unknown escapes keep the backslash, matching how a shell treats them
        // inside double quotes.
        default: "\\\(character)"
        }
    }

    private static func duplicateWarnings(in entries: [DotenvEntry]) -> [DotenvDiagnostic] {
        var seen: [EnvKey: Int] = [:]
        var warnings: [DotenvDiagnostic] = []
        for entry in entries {
            if let first = seen[entry.key] {
                warnings.append(.init(
                    severity: .warning, line: entry.line,
                    message: "\(entry.key) was already defined on line \(first). The later value wins."))
            }
            seen[entry.key] = entry.line
        }
        return warnings
    }
}
