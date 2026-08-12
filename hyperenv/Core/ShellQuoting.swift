//
//  ShellQuoting.swift
//  hyperenv
//

import Foundation

nonisolated enum ShellQuoting {

    /// Wraps a value in single quotes, which is the only POSIX construct that
    /// suppresses *all* interpretation — `$`, backticks, `\`, `#`, `!`, spaces
    /// and newlines all pass through literally.
    ///
    /// A single quote cannot be escaped inside single quotes, so the standard
    /// close/insert/reopen dance is used: `it's` becomes `'it'\''s'`.
    ///
    /// Values are quoted unconditionally, even trivially safe ones. `abc` today
    /// invites a hand-edit to `abc def` tomorrow, and consistency is worth more
    /// than prettier output.
    static func singleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Double-quoted form for dotenv parsers, which generally do not implement
    /// POSIX single-quote semantics. Newlines become `\n` because most of those
    /// parsers cannot handle a literal newline inside a value.
    static func doubleQuote(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count + 2)
        for character in value {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "$": out += "\\$"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(character)
            }
        }
        return "\"" + out + "\""
    }
}
