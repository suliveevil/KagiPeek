import Foundation

/// Reads a query that spells out a key combo and turns it into a chord.
///
/// The point is to answer "what uses ⌘⇧4?" without making the user hunt for it in a list
/// of conflicts, which by construction only shows combos *two* things claim. A combo one
/// thing owns alone used to come back as an empty list, and an empty list reads as "not
/// scanned" rather than "nobody else wants this".
///
/// Parsing is deliberately strict: every token has to be a modifier or a key name, there
/// has to be exactly one key, and there has to be at least one modifier. The modifier rule
/// keeps a bare "t" or "safari" from being read as a combo; the every-token rule keeps
/// "cmd safari" a plain text search.
nonisolated enum ComboQuery {

    static func chord(from query: String) -> KeyChord? {
        var text = query.lowercased()
        // Glyphs and "+" become spaces so "⌥⌘t" and "cmd+t" split the same way
        // "opt cmd t" does.
        for (glyph, word) in [("⌘", " cmd "), ("⌥", " opt "), ("⇧", " shift "), ("⌃", " ctrl "), ("+", " ")] {
            text = text.replacingOccurrences(of: glyph, with: word)
        }

        var modifiers: ModifierSet = []
        var key: KeyToken?
        for token in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            if let modifier = modifier(forWord: token) {
                modifiers.insert(modifier)
                continue
            }
            // "left arrow" is how a spelled-out key reads; "left" alone already names it.
            if token == "arrow" { continue }
            guard key == nil, let token = Self.key(forWord: token) else { return nil }
            key = token
        }

        guard let key, !modifiers.isEmpty else { return nil }
        return .combo(modifiers, key)
    }

    // MARK: - Words

    static func modifier(forWord word: String) -> ModifierSet? {
        switch word {
        case "cmd", "command": return .command
        case "opt", "option", "alt": return .option
        case "shift": return .shift
        case "ctrl", "control": return .control
        default: return nil
        }
    }

    /// Resolves one word to a key token, accepting both the token itself and the names
    /// people actually type ("escape", "backspace", "enter").
    static func key(forWord word: String) -> KeyToken? {
        if let alias = aliases[word] { return alias }
        guard knownTokens.contains(word) else { return nil }
        return KeyToken(word)
    }

    /// Every token `KeyMapper` can produce for the standard key range.
    ///
    /// Built from the mapper rather than listed here, so a key added to the table is
    /// searchable the moment it exists instead of the second time somebody remembers to
    /// update a second list.
    private static let knownTokens: Set<String> = {
        var tokens: Set<String> = []
        for code in UInt16(0)...0x7F {
            if let token = KeyMapper.token(forKeyCode: code) {
                tokens.insert(token.raw)
            }
        }
        return tokens
    }()

    private static let aliases: [String: KeyToken] = [
        "escape": "esc", "esc": "esc",
        "enter": "return", "return": "return",
        "backspace": "delete", "del": "delete", "delete": "delete",
        "forwarddelete": "fdelete",
        "pageup": "pageup", "pagedown": "pagedown"
    ]
}

/// Answers "what uses this combo?" over everything a scan knows about.
nonisolated enum ComboLookup {

    enum Answer: Equatable, Sendable {
        /// Nothing claims the combo.
        case free(KeyChord)
        /// One or more shortcuts claim it. A single owner is not a conflict, which is
        /// exactly why the conflict list stayed silent and this has to speak up.
        case claimed(KeyChord, owners: [BindingItem])

        var items: [BindingItem] {
            if case .claimed(_, let owners) = self { return owners }
            return []
        }
    }

    /// Matched on the chord's cache key, the same way `ConflictDetector` groups bindings,
    /// so a lookup and the conflict list can never disagree about who owns a combo.
    static func owners(of chord: KeyChord, in items: [BindingItem]) -> [BindingItem] {
        let target = chord.cacheKey
        return items.filter { $0.chord.cacheKey == target }
    }

    static func answer(for chord: KeyChord, in items: [BindingItem]) -> Answer {
        let owners = owners(of: chord, in: items)
        return owners.isEmpty ? .free(chord) : .claimed(chord, owners: owners)
    }

    /// The answer for a query, or nil when the query is not a combo at all.
    ///
    /// Returning nil is what keeps plain text searches behaving as searches: only a query
    /// that spells out a combo gets the direct answer.
    static func answer(forQuery query: String, in items: [BindingItem]) -> Answer? {
        guard let chord = ComboQuery.chord(from: query) else { return nil }
        return answer(for: chord, in: items)
    }
}
