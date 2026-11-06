import Foundation

/// The panel's filter, as an ordered queue of modifier and letter tokens.
///
/// The queue is the point: ⌃ then F filters on "⌃ F", and ⌫ takes back the *last* thing
/// the user added — a letter if the letter came last, a modifier if the modifier did.
/// A set would lose that order and make ⌫ guess.
nonisolated struct PanelFilter: Equatable, Sendable {
    enum Token: Equatable, Sendable {
        case modifier(ModifierSet)
        case letter(Character)
    }

    private(set) var tokens: [Token]

    init(tokens: [Token] = []) {
        self.tokens = tokens
    }

    var isEmpty: Bool { tokens.isEmpty }

    /// Every modifier token, unioned: what the rows are narrowed by.
    var modifiers: ModifierSet {
        tokens.reduce(ModifierSet()) { result, token in
            guard case .modifier(let modifier) = token else { return result }
            return result.union(modifier)
        }
    }

    var letters: [Character] {
        tokens.compactMap { token in
            guard case .letter(let character) = token else { return nil }
            return character
        }
    }

    /// What the search corpus is queried with: modifier glyphs and lowercase letters in
    /// queue order, separated by spaces — "⌃ f".
    var query: String {
        tokens.map { token in
            switch token {
            case .letter(let character):
                return String(character).lowercased()
            case .modifier(let modifier):
                return modifier.ordered.map(KeyFormatter.symbol(for:)).joined()
            }
        }
        .joined(separator: " ")
    }

    /// Adds the modifier at the tail, or removes it wherever it already sits.
    ///
    /// Removing from the middle is deliberate: pressing ⌃ while the queue holds ⌃ ⌥ F must
    /// leave ⌥ F in that order, not rebuild it around ⌃.
    mutating func toggleModifier(_ modifier: ModifierSet) {
        if let index = tokens.firstIndex(of: .modifier(modifier)) {
            tokens.remove(at: index)
        } else {
            tokens.append(.modifier(modifier))
        }
    }

    mutating func appendLetter(_ character: Character) {
        let lowered = String(character).lowercased()
        tokens.append(.letter(lowered.first ?? character))
    }

    @discardableResult
    mutating func popLastToken() -> Token? {
        tokens.popLast()
    }

    mutating func clear() {
        tokens.removeAll()
    }
}
