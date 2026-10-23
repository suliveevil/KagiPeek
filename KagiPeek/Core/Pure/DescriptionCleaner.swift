import Foundation

/// Cleans up menu titles before they hit the panel.
///
/// Accessibility returns raw menu titles: mixed tabs, trailing shortcut glyphs on some
/// apps, duplicated whitespace, leading "+" markers. The panel has a fixed column width,
/// so titles are also truncated here.
enum DescriptionCleaner {
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
        return text.isEmpty ? "—" : text
    }

    static func truncate(_ text: String, maxLength: Int) -> String {
        guard maxLength > 1 else { return text }
        guard text.count > maxLength else { return text }
        return text.prefix(maxLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }
}
