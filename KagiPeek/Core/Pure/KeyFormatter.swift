import Foundation

/// Renders chords the way macOS does: `⌃⌥⇧⌘` order, no separators, `⇧⌘3`.
enum KeyFormatter {
    enum Style: String, Codable, CaseIterable, Hashable, Sendable {
        case symbols
        case words

        var l10nKey: L10nKey {
            self == .symbols ? .appearanceStyleSymbols : .appearanceStyleWords
        }
    }

    static func render(_ chord: KeyChord, style: Style) -> String {
        segments(for: chord, style: style).map(\.text).joined()
    }

    static func render(step: KeyStep, style: Style) -> String {
        segments(for: step, style: style).map(\.text).joined()
    }

    /// What a command with no keyboard shortcut shows where the chord would be.
    ///
    /// A blank shortcut column reads as a rendering bug; a dash reads as "this command has
    /// no shortcut", which is also the only kind of row that is triggered by pressing the
    /// menu item itself rather than by typing.
    static let noShortcutPlaceholder = "—"

    /// One piece of a rendered chord.
    ///
    /// The panel shows a whole chord and lights up the modifier the user is holding, which
    /// a `String` cannot express. Splitting the glyphs here — instead of in the view, which
    /// would re-parse the formatted text — keeps `render` and the segmented form from ever
    /// disagreeing: `render` is the segmented form joined back together.
    struct Segment: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case modifier(ModifierSet)
            case key
            /// Spacing between glyphs or between strokes of a chord.
            case separator
        }

        let kind: Kind
        let text: String
    }

    static func segments(for chord: KeyChord, style: Style) -> [Segment] {
        var result: [Segment] = []
        for (index, step) in chord.steps.enumerated() {
            if index > 0 {
                result.append(Segment(kind: .separator, text: style == .symbols ? " " : ", "))
            }
            result.append(contentsOf: segments(for: step, style: style))
        }
        return result
    }

    static func segments(for step: KeyStep, style: Style) -> [Segment] {
        var result: [Segment] = []
        let separator = style == .symbols ? "" : " + "
        for modifier in step.modifiers.ordered {
            if !result.isEmpty, !separator.isEmpty {
                result.append(Segment(kind: .separator, text: separator))
            }
            result.append(Segment(
                kind: .modifier(modifier),
                text: style == .symbols ? symbol(for: modifier) : word(for: modifier)
            ))
        }
        if let key = step.key {
            if !result.isEmpty, !separator.isEmpty {
                result.append(Segment(kind: .separator, text: separator))
            }
            result.append(Segment(kind: .key, text: label(for: key, style: style)))
        }
        return result
    }

    static func symbol(for modifier: ModifierSet) -> String {
        if modifier == .control { return "⌃" }
        if modifier == .option { return "⌥" }
        if modifier == .shift { return "⇧" }
        return "⌘"
    }

    static func word(for modifier: ModifierSet) -> String {
        if modifier == .control { return "control" }
        if modifier == .option { return "option" }
        if modifier == .shift { return "shift" }
        return "command"
    }

    static func label(for key: KeyToken, style: Style) -> String {
        if style == .words {
            switch key.raw {
            case "esc": return "escape"
            case "fdelete": return "delete"
            case "left": return "←"
            case "right": return "→"
            case "up": return "↑"
            case "down": return "↓"
            default:
                return key.raw.count == 1 ? key.raw.uppercased() : key.raw
            }
        }

        switch key.raw {
        case "return", "enter": return "↩"
        case "tab": return "⇥"
        case "space": return "␣"
        case "delete": return "⌫"
        case "fdelete": return "⌦"
        case "esc": return "⎋"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "home": return "↖"
        case "end": return "↘"
        case "pageup": return "⇞"
        case "pagedown": return "⇟"
        case "help": return "?"
        default:
            if key.raw.count == 1, let character = key.raw.first, character.isLetter {
                return key.raw.uppercased()
            }
            if key.raw.hasPrefix("f"), let number = Int(key.raw.dropFirst()), (1...20).contains(number) {
                return "F\(number)"
            }
            return key.raw
        }
    }

    /// The compact form used in breadcrumbs ("⌘" / "⌘K").
    static func breadcrumb(for chord: KeyChord, style: Style) -> [String] {
        chord.steps.map { render(step: $0, style: style) }
    }
}
