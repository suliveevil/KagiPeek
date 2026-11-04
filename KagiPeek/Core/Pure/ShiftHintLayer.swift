import Foundation

/// The zero-to-nine / a-to-z labels the panel shows while Shift is held.
///
/// The draft asks for the first 36 shortcuts to be overlaid with labels so one swipe of
/// Shift plus a letter can run a row without reading the chord. The label table is the
/// whole mechanism: index → glyph, and glyph → index. It lives in pure code because the
/// hardware keyboard never sees these labels — they are a model the panel and the key
/// handler have to agree on.
nonisolated enum ShiftHintLayer {
    /// 0–9 and a–z: ten digits plus twenty-six letters.
    static let capacity = 36

    static let labels: [String] = {
        let digits = (0...9).map(String.init)
        let letters = (0..<26).compactMap { UnicodeScalar(97 + $0).map(String.init) }
        return digits + letters
    }()

    /// The label for a position in the panel's sequence. Positions past the table have no
    /// label — a 37th row stays unlabelled rather than repeating a glyph.
    static func label(forIndex index: Int) -> String? {
        guard index >= 0, index < labels.count else { return nil }
        return labels[index]
    }

    /// Item id → label, assigned from the panel's current sequence.
    ///
    /// Rebuilt from the ordered ids every time the panel is built, so changing the sort
    /// order moves the labels with the display position instead of pinning a glyph to a
    /// menu item.
    static func labels(for ids: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for (index, id) in ids.prefix(capacity).enumerated() {
            if let label = label(forIndex: index) {
                result[id] = label
            }
        }
        return result
    }

    /// The position a typed character addresses. Case is folded, so Shift+A and Shift+a are
    /// the same position; a multi-character or non-ASCII key answers nil and the panel's
    /// normal handling takes it.
    static func index(forCharacter character: String) -> Int? {
        guard character.count == 1 else { return nil }
        return labels.firstIndex(of: character.lowercased())
    }
}
