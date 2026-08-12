//
//  EnvOutputParser.swift
//  hyperenv
//
//  Parses NUL-separated `env -0` output.
//

import Foundation

nonisolated enum EnvOutputParser {

    /// Everything the probe prints before this marker is discarded.
    ///
    /// An interactive zsh runs the user's prompt framework, plugin managers and
    /// completion setup, any of which may print banners or warnings to stdout.
    /// Framing the real payload is what makes the probe survive a chatty
    /// `.zshrc` instead of choking on it.
    static let sentinel = "<<<HYPERENV-ENV-BEGIN>>>"

    /// `env -0` separates records with NUL, which is the only byte that cannot
    /// appear inside a value — so newlines inside values round-trip intact.
    static func parseNulSeparated(_ data: Data, sentinel: String = sentinel) throws -> EnvSet {
        let marker = Data(sentinel.utf8)
        guard let range = data.range(of: marker) else {
            throw HyperEnvError.probeSentinelMissing
        }

        let payload = data[range.upperBound...]
        var result = EnvSet()

        for record in payload.split(separator: 0, omittingEmptySubsequences: true) {
            // Decoded per record so a single undecodable value cannot discard
            // the entire environment.
            guard let text = String(data: Data(record), encoding: .utf8) else { continue }
            guard let separator = text.firstIndex(of: "=") else { continue }

            let name = String(text[text.startIndex..<separator])
            guard let key = EnvKey(name) else { continue }

            result[key] = EnvValue(String(text[text.index(after: separator)...]))
        }

        return result
    }
}
