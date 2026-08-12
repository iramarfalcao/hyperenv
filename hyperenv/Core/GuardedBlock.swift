//
//  GuardedBlock.swift
//  hyperenv
//
//  Idempotent insertion and removal of a marker-delimited block inside a file
//  the user also edits by hand.
//
//  This is deliberately a pure String -> String transform. It is the single
//  most dangerous operation in the app — it rewrites `~/.zprofile`, a file that
//  can break the user's login shell — so it carries no I/O at all and every
//  edge case is reachable from a unit test with a fixture string.
//

import Foundation

nonisolated struct BlockMarkers: Sendable, Equatable {
    let begin: String
    let end: String

    /// Detection matches on these prefixes rather than the full marker text, so
    /// a future version that changes the trailing note can still find — and
    /// migrate — a block written by v1.
    static let beginPrefix = "# >>> hyperenv managed block"
    static let endPrefix = "# <<< hyperenv managed block"

    static let v1 = BlockMarkers(
        begin: "\(beginPrefix) v1 >>> (do not edit)",
        end: "\(endPrefix) v1 <<<"
    )
}

nonisolated enum GuardedBlock {

    // MARK: - Line model

    /// A file decomposed into lines plus the two properties that must survive a
    /// round trip: which terminator it uses, and whether it ended with one.
    /// Losing either would show up as spurious whole-file diffs in the user's
    /// dotfiles repo.
    struct LineModel: Equatable {
        var lines: [String]
        var usesCRLF: Bool
        var hasTrailingNewline: Bool

        /// Parses over unicode scalars rather than `Character`s on purpose.
        /// Swift treats CRLF as a *single* grapheme cluster, so `hasSuffix("\n")`
        /// is false for a CRLF-terminated file and splitting on `"\n"` does not
        /// see the newline inside `"\r\n"` — both of which silently corrupt
        /// Windows-authored dotfiles.
        init(parsing content: String) {
            var normalized: [Unicode.Scalar] = []
            normalized.reserveCapacity(content.unicodeScalars.count)

            var sawCRLF = false
            var iterator = content.unicodeScalars.makeIterator()
            var pending: Unicode.Scalar? = iterator.next()

            while let scalar = pending {
                if scalar == "\r" {
                    let next = iterator.next()
                    if next == "\n" {
                        sawCRLF = true
                        pending = iterator.next()
                    } else {
                        pending = next  // lone CR, treated as a line break
                    }
                    normalized.append("\n")
                    continue
                }
                normalized.append(scalar)
                pending = iterator.next()
            }

            usesCRLF = sawCRLF
            hasTrailingNewline = normalized.last == "\n"
            if hasTrailingNewline { normalized.removeLast() }

            if normalized.isEmpty && !hasTrailingNewline {
                lines = []
            } else {
                lines = String(String.UnicodeScalarView(normalized))
                    .components(separatedBy: "\n")
            }
        }

        func rendered() -> String {
            let terminator = usesCRLF ? "\r\n" : "\n"
            var out = lines.joined(separator: terminator)
            if hasTrailingNewline { out += terminator }
            return out
        }
    }

    // MARK: - Span location

    private static func isBegin(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(BlockMarkers.beginPrefix)
    }

    private static func isEnd(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(BlockMarkers.endPrefix)
    }

    /// Locates the managed block, or throws if the file is in a state where
    /// guessing could destroy user content.
    ///
    /// Matching is exact-prefix on a trimmed line, so a marker quoted inside a
    /// user's own comment (`# see the "# >>> hyperenv" block`) does not count.
    static func findSpan(in lines: [String], path: String = "file") throws -> ClosedRange<Int>? {
        let begins = lines.indices.filter { isBegin(lines[$0]) }
        let ends = lines.indices.filter { isEnd(lines[$0]) }

        switch (begins.count, ends.count) {
        case (0, 0):
            return nil
        case (1, 1):
            guard ends[0] > begins[0] else {
                throw HyperEnvError.unbalancedMarkers(
                    path: path,
                    detail: "the end marker on line \(ends[0] + 1) comes before the begin marker on line \(begins[0] + 1)"
                )
            }
            return begins[0]...ends[0]
        case (0, _):
            throw HyperEnvError.unbalancedMarkers(
                path: path, detail: "an end marker on line \(ends[0] + 1) with no begin marker")
        case (_, 0):
            throw HyperEnvError.unbalancedMarkers(
                path: path, detail: "a begin marker on line \(begins[0] + 1) with no end marker")
        default:
            throw HyperEnvError.unbalancedMarkers(
                path: path,
                detail: "\(begins.count) begin and \(ends.count) end markers; expected exactly one of each")
        }
    }

    // MARK: - Install

    /// Inserts or refreshes the block.
    ///
    /// - When no block exists it is appended, because in `.zprofile` the last
    ///   assignment wins and we need to land after things like `brew shellenv`.
    /// - When a block exists it is replaced **in place**, preserving its
    ///   position, so a user who deliberately moved it keeps their ordering.
    ///
    /// Returns the new content; identical input and output means the caller
    /// should skip the write entirely.
    static func install(
        into content: String,
        body: [String],
        markers: BlockMarkers = .v1,
        path: String = "file"
    ) throws -> String {
        var model = LineModel(parsing: content)
        let block = [markers.begin] + body + [markers.end]

        if let span = try findSpan(in: model.lines, path: path) {
            model.lines.replaceSubrange(span, with: block)
        } else {
            let fileWasEmpty = model.lines.isEmpty

            // Separate from existing content with exactly one blank line, and
            // only when there is content to separate from.
            if let last = model.lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                model.lines.append("")
            }
            model.lines.append(contentsOf: block)

            // Only a brand-new file gets a trailing newline imposed on it.
            // Adding one to a file that lacked it would break the guarantee
            // that install-then-remove is byte-identical.
            if fileWasEmpty { model.hasTrailingNewline = true }
        }

        return model.rendered()
    }

    // MARK: - Remove

    /// Deletes the block, plus the single blank separator line `install` adds.
    /// A file with no block is returned untouched.
    static func remove(
        from content: String,
        path: String = "file"
    ) throws -> String {
        var model = LineModel(parsing: content)
        guard let span = try findSpan(in: model.lines, path: path) else { return content }

        var lower = span.lowerBound
        if lower > 0, model.lines[lower - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            lower -= 1
        }

        model.lines.removeSubrange(lower...span.upperBound)
        if model.lines.isEmpty { model.hasTrailingNewline = false }

        return model.rendered()
    }

    // MARK: - Inspection

    /// The block's inner lines, excluding the markers themselves.
    static func extractBody(from content: String, path: String = "file") throws -> [String]? {
        let model = LineModel(parsing: content)
        guard let span = try findSpan(in: model.lines, path: path) else { return nil }
        guard span.count > 2 else { return [] }
        return Array(model.lines[(span.lowerBound + 1)..<span.upperBound])
    }

    static func containsBlock(_ content: String) -> Bool {
        (try? findSpan(in: LineModel(parsing: content).lines)) .flatMap { $0 } != nil
    }
}
