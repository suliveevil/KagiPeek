import Foundation

/// One optional pair of punctuation keys that page the panel.
///
/// The four pairs are independent: the settings are checkboxes, not a picker, so several
/// pairs can be enabled at once and every one of them pages. The first stroke of each pair
/// means "previous", the second means "next".
nonisolated enum PagingPair: String, Codable, CaseIterable, Hashable, Sendable {
    case commaPeriod
    case brackets
    case minusEqual
    case semicolonQuote

    var previous: PagingStroke {
        switch self {
        case .commaPeriod:
            return PagingStroke(character: ",", keyCode: KeyCode.comma, modifiers: [])
        case .brackets:
            return PagingStroke(character: "[", keyCode: KeyCode.leftBracket, modifiers: [])
        case .minusEqual:
            return PagingStroke(character: "-", keyCode: KeyCode.minus, modifiers: [])
        case .semicolonQuote:
            return PagingStroke(character: ";", keyCode: KeyCode.semicolon, modifiers: [])
        }
    }

    var next: PagingStroke {
        switch self {
        case .commaPeriod:
            return PagingStroke(character: ".", keyCode: KeyCode.period, modifiers: [])
        case .brackets:
            return PagingStroke(character: "]", keyCode: KeyCode.rightBracket, modifiers: [])
        case .minusEqual:
            // Both are unshifted on the ANSI layout: `-` is key 27, `=` is key 24. `+`
            // (Shift+=) is deliberately not a paging character.
            return PagingStroke(character: "=", keyCode: KeyCode.equal, modifiers: [])
        case .semicolonQuote:
            return PagingStroke(character: "'", keyCode: KeyCode.quote, modifiers: [])
        }
    }

    var titleKey: L10nKey {
        switch self {
        case .commaPeriod: return .pagingPairCommaPeriod
        case .brackets: return .pagingPairBrackets
        case .minusEqual: return .pagingPairMinusEqual
        case .semicolonQuote: return .pagingPairSemicolonQuote
        }
    }
}

/// One physical spelling of a paging key, used only when the event carries no character.
nonisolated struct PagingStroke: Equatable, Sendable {
    var character: Character
    var keyCode: UInt16
    var modifiers: ModifierSet
}

/// The single decision: which paging pair (if any) owns this key.
///
/// Both the panel router and the event tap's swallow list read this, so the key that pages
/// and the key that is consumed cannot drift. The decision is **character-first**: the
/// character the active layout produced is what the user sees, and on a Pinyin layout the
/// semicolon key types `；` rather than `;`. Full-width punctuation is folded back to ASCII
/// before the comparison. The ANSI key code is a fallback for events with no decoded
/// character (synthetic events, or a tap that is not decoding).
nonisolated enum PagingKeyPlan {
    /// Full-width punctuation the CJK layouts produce, folded to the ASCII key it stands for.
    private static let canonicalMap: [Character: Character] = [
        "，": ",", "。": ".", "、": ",",
        "［": "[", "］": "]",
        "－": "-",
        "；": ";", "＇": "'", "’": "'"
    ]

    static func canonical(_ character: Character) -> Character {
        canonicalMap[character] ?? character
    }

    /// The step for this key, or `nil` when it is not a paging key.
    ///
    /// No paging pair needs a modifier of its own, but Shift is tolerated: a layout may
    /// spell a punctuation character with it. ⌘/⌥/⌃ are shortcut layers and never page,
    /// because they change what the key types.
    static func step(
        pairs: Set<PagingPair>,
        keyCode: UInt16,
        modifiers: ModifierSet,
        characters: String?
    ) -> Int? {
        guard modifiers.subtracting([.shift]).isEmpty else { return nil }

        if let first = characters?.first {
            let character = canonical(first)
            for pair in ordered(pairs) {
                if character == pair.previous.character { return -1 }
                if character == pair.next.character { return 1 }
            }
            // The event decoded a character, so the physical code must not be consulted:
            // the same key code can type something else on another layout.
            return nil
        }

        for pair in ordered(pairs) {
            if keyCode == pair.previous.keyCode, modifiers == pair.previous.modifiers { return -1 }
            if keyCode == pair.next.keyCode, modifiers == pair.next.modifiers { return 1 }
        }
        return nil
    }

    /// Every character the enabled pairs can produce, for the tap's character channel.
    ///
    /// The full-width variants are included because that is what the event actually carries
    /// on a CJK layout; `canonical` would fold them later, but the tap compares raw values.
    static func characters(for pairs: Set<PagingPair>) -> Set<Character> {
        var result: Set<Character> = []
        for pair in pairs {
            result.formUnion(variants(of: pair.previous.character))
            result.formUnion(variants(of: pair.next.character))
        }
        return result
    }

    private static func variants(of character: Character) -> Set<Character> {
        var result: Set<Character> = [character]
        for (fullWidth, ascii) in canonicalMap where ascii == character {
            result.insert(fullWidth)
        }
        return result
    }

    /// `Set` iteration order is not stable; the settings list and the tests use the declared
    /// order so `,` is always tried before `;` and logging does not churn.
    static func ordered(_ pairs: Set<PagingPair>) -> [PagingPair] {
        PagingPair.allCases.filter(pairs.contains)
    }
}
