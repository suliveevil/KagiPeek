import Foundation

/// The geometry of one panel row: three columns — function, menu path, shortcut.
///
/// The row used to be one `HStack` of natural-width views: the title, then the menu path if
/// the binding had one, then a conflict badge **if** there was a conflict, then the star,
/// then the chord. Every one of those was optional, so each column started at a different
/// x on every row: the menu paths did not line up, and a row with a ⚠︎ pushed the chord
/// about 17pt to the left of its neighbours.
///
/// The fix is to give every column a width that does not depend on the row's content:
///
/// - the menu path is a fixed slot, truncated in the middle (a path is read from both ends);
/// - the trailing slot — conflict badge and favourite star — is **always** reserved, the
///   badge just goes transparent when there is no conflict, so the chord never moves;
/// - the chord is capped, so a `words`-style chord cannot overflow a two-column panel;
/// - the title takes whatever is left.
///
/// The row reads as two clusters rather than three islands: the command on the left, and
/// `path · badge · chord` packed against the right edge. The chord slot is sized by the
/// chord *style* (a two-glyph chord does not need the width of `ctrl opt shift cmd K`), and
/// the menu path is right-aligned inside its slot so it sits next to the chord instead of
/// floating a quarter of the way across a wide row. The only slack left is between the
/// command and that cluster, where a table would put it.
///
/// All of it is arithmetic on doubles, like `HeaderLayout`, so the thresholds can be tested
/// without a window.
enum RowLayout {
    /// Conflict badge (12) + gap (4) + sub-level chevron (8) + gap (4) + favourite star (14).
    ///
    /// Reserved on every row, conflict or not: this is the slot whose appearance used to
    /// shift the shortcut column sideways. The chevron is in here rather than beside the menu
    /// path so that it survives the narrow panel, where that column is dropped.
    static let gutterWidth: Double = 44
    /// Tighter than `columnGap` so all three markers fit the reserved slot.
    static let gutterSpacing: Double = 4
    /// The row's own horizontal padding, applied on both sides.
    static let horizontalPadding: Double = 8
    /// Gap between two columns.
    static let columnGap: Double = 8
    /// Gap between two grid columns (matches the `LazyVGrid` spacing).
    static let columnSpacing: Double = 28
    /// The slot for the "has a sub-level" chevron, inside the trailing gutter.
    static let chevronWidth: Double = 8
    /// Below this the menu path is dropped: a 300pt panel is one column beside a window and
    /// needs the width for the command name.
    static let noteThreshold: Double = 300
    /// Above this the menu path gets the wider share of the row.
    static let wideThreshold: Double = 380

    struct Metrics: Equatable {
        var rowWidth: Double
        var rowContentWidth: Double
        var showsNote: Bool
        var noteWidth: Double
        var keyWidth: Double
        var titleWidth: Double
        var gutterWidth: Double
        /// The menu path sits next to the chord, so its text is aligned to the slot's trailing
        /// edge. With the chord on the left the path follows the title instead and reads from
        /// its leading edge.
        var noteHugsChord: Bool
    }

    /// Width of the chord slot, per chord style.
    ///
    /// Measured at 12.5pt semibold: `⌘A` is 20pt, `⇧⌘4` is 33pt, `⌃⌥⇧⌘Q` is 57pt, while the
    /// words style needs 69pt for `cmd shift 4` and 117pt for `ctrl opt shift cmd K`. One cap
    /// for both styles parked ~50pt of empty column between the path and a two-glyph chord.
    static func keyWidthCap(for style: KeyFormatter.Style) -> Double {
        switch style {
        case .symbols: return 70
        case .words: return 132
        }
    }

    /// Width of one row when `columns` rows share `contentWidth`.
    static func rowWidth(contentWidth: Double, columns: Int, spacing: Double = columnSpacing) -> Double {
        guard columns > 1 else { return max(0, contentWidth) }
        let usable = contentWidth - spacing * Double(columns - 1)
        return max(0, usable / Double(columns))
    }

    static func metrics(
        rowWidth: Double,
        keyPosition: KeyPosition,
        keyStyle: KeyFormatter.Style = .symbols
    ) -> Metrics {
        let content = max(0, rowWidth - horizontalPadding * 2)
        let showsNote = rowWidth >= noteThreshold
        let note = showsNote ? noteWidth(rowWidth: rowWidth, content: content) : 0
        let key = keyWidth(content: content, style: keyStyle)
        // Everything except the title is reserved. The chord is subtracted in both positions:
        // it is part of the trailing cluster, so leaving it out would let a long title push
        // the chord out of the row instead of truncating the title.
        //
        // The gap count is the number of column boundaries: title, menu path, trailing slot
        // and chord are four slots, so three gaps once the menu path is shown.
        let reserved = key + note + gutterWidth + columnGap * (showsNote ? 3 : 2)
        let title = max(60, content - reserved)
        return Metrics(
            rowWidth: rowWidth,
            rowContentWidth: content,
            showsNote: showsNote,
            noteWidth: note,
            keyWidth: key,
            titleWidth: title,
            gutterWidth: gutterWidth,
            noteHugsChord: keyPosition == .right
        )
    }

    private static func noteWidth(rowWidth: Double, content: Double) -> Double {
        if rowWidth >= wideThreshold {
            return clamped(0.34 * content, lower: 88, upper: 168)
        }
        return clamped(0.28 * content, lower: 64, upper: 108)
    }

    private static func keyWidth(content: Double, style: KeyFormatter.Style) -> Double {
        clamped(0.28 * content, lower: 52, upper: keyWidthCap(for: style))
    }

    private static func clamped(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
