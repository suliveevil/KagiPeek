import Foundation

/// The zero-to-nine / a-to-z labels the panel shows while the hint layer is up.
///
/// A tap of Shift overlays the first 36 shortcuts with labels; a bare glyph then runs the
/// corresponding row without reading the chord. Keeping Shift out of the addressing press
/// is the point: the row's own chord can then be replayed into the front app without a
/// physical ⇧ being mixed into it. The label table is the whole mechanism: index → glyph,
/// and glyph → index. It lives in pure code because the hardware keyboard never sees these
/// labels — they are a model the panel and the key handler have to agree on.
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

    /// The position a typed character addresses on a page with `pageRowCount` visible rows.
    ///
    /// Hints are numbered per page, so a glyph whose number falls past this page's last row
    /// addresses nothing: Shift+O on a ten-row page must not run the row it would label on a
    /// later page.
    static func index(forCharacter character: String, pageRowCount: Int) -> Int? {
        guard let index = index(forCharacter: character), index < pageRowCount else { return nil }
        return index
    }

    /// The row a bare glyph press addresses, read from the event rather than from the
    /// character alone.
    ///
    /// A label names the physical key the finger hit, so a press whose character is not a
    /// label — or that decodes no character at all, as a virtual keyboard can — falls back
    /// to the virtual key code, the second spelling of the same press. That also keeps a
    /// non-ANSI layout pointing at the row its key is labelled with.
    ///
    /// `pageRowCount` is the number of rows on screen. The caller that swallows the press
    /// and the caller that runs the row both pass it, so a glyph past the last row is
    /// neither swallowed nor executed.
    static func index(for event: KeyEvent, pageRowCount: Int? = nil) -> Int? {
        if let key = event.key, let index = bounded(key.raw, pageRowCount: pageRowCount) {
            return index
        }
        guard let physical = KeyMapper.token(forKeyCode: event.keyCode) else { return nil }
        return bounded(physical.raw, pageRowCount: pageRowCount)
    }

    private static func bounded(_ character: String, pageRowCount: Int?) -> Int? {
        guard let index = index(forCharacter: character) else { return nil }
        if let pageRowCount, index >= pageRowCount { return nil }
        return index
    }
}
