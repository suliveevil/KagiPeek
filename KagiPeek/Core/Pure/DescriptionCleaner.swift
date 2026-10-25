import Foundation

/// Cleans up menu titles before they hit the panel.
///
/// Accessibility returns raw menu titles: mixed tabs, trailing shortcut glyphs on some
/// apps, duplicated whitespace, leading "+" markers. The panel has a fixed column width,
/// so titles are also truncated here.
///
/// Nonisolated: pure string work called from the nonisolated binding builders.
nonisolated enum DescriptionCleaner {
    /// What a row shows when there is no name to show. A single em dash is the typographic
    /// way of saying "nothing here", and it is visibly not a description — unlike repeating
    /// the shortcut, which read as if the description had been lost.
    static let placeholder = "—"

    private static let shortcutGlyphs = CharacterSet(charactersIn: "⌘⌥⌃⇧⌫⌦↩⇥⎋←→↑↓⇞⇟↖↘␣")

    static func clean(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        text = text.trimmingCharacters(in: .whitespaces)

        // Strip a trailing "⌘S"-style hint (menu titles sometimes include it) so the
        // title is not duplicated by our own keycap.
        if let hintRange = text.range(of: "\\s+[⌘⌥⌃⇧][^\\s]{0,7}$", options: .regularExpression) {
            text.removeSubrange(hintRange)
        }

        text = text.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("+") {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? placeholder : text
    }

    static func truncate(_ text: String, maxLength: Int) -> String {
        guard maxLength > 1 else { return text }
        guard text.count > maxLength else { return text }
        return text.prefix(maxLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}
