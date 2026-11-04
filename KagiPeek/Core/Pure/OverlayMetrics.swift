import CoreGraphics
import Foundation

/// Layout maths shared by the panel controller (window sizing) and the SwiftUI view so the
/// two can never disagree.
///
/// Deliberately free of AppKit and SwiftUI: the height the panel window takes is a number
/// that can be asserted in a test, and "does narrowing resize the window" is exactly the
/// kind of regression that is invisible in a screenshot but obvious in an assertion.
nonisolated enum OverlayMetrics {
    static let columnWidth: CGFloat = 248
    static let rowHeight: CGFloat = 30
    static let padding: CGFloat = 14
    static let groupHeaderHeight: CGFloat = 24
    /// One section of the panel is a card: its rows sit inside it, and the cards are apart.
    static let cardHorizontalInset: CGFloat = 6
    static let cardVerticalInset: CGFloat = 4
    static let cardGap: CGFloat = 10
    /// The hairline under a card's title strip, drawn inside the header's reserved height.
    static let cardRuleHeight: CGFloat = 1
    static let maxPanelHeight: CGFloat = 720
    static let minPanelHeight: CGFloat = 190
    /// The title bar, the hairline under it, and the footer. The SwiftUI views read these
    /// too, so "content height = panel height − footer" is one number instead of two copies.
    static let headerHeight: CGFloat = 54
    static let footerHeight: CGFloat = 32
    static let ruleHeight: CGFloat = 1
    /// Padding inside the list's scroll view: 8 above the first card, 10 below the last.
    static let contentTopPadding: CGFloat = 8
    static let contentBottomPadding: CGFloat = 10
    /// Everything that is not a row: header + rule + footer + the list's own padding.
    /// A page may never use this space, so the footer cannot sit on top of a row.
    static let chromeHeight: CGFloat = headerHeight + ruleHeight + footerHeight
        + contentTopPadding + contentBottomPadding

    /// The grid stride used to count how many columns a *screen* holds when the panel covers
    /// it. Deliberately not `columnWidth + columnSpacing`: that is the natural width of one
    /// column at cheat-sheet density (248 pt), while a screen-filling page can afford a
    /// three-hundred-point column and fits more rows per column. Using one number for both
    /// made the fill-screen page shorter than the window it was drawn in.
    static let denseColumnStride: CGFloat = 300
    /// What the screen keeps for itself — menu bar, Dock and the panel's own chrome — before
    /// any row is counted.
    static let screenVerticalReserve: CGFloat = 150

    /// Gap between adjacent grid columns, kept in sync with `RowLayout.columnSpacing`.
    static let columnSpacing: CGFloat = 18

    /// How many rows one page holds when the panel fills the screen: the page grows with the
    /// display instead of sticking to the small-window limit.
    ///
    /// Pure, and asserted in a test, because "does the fill-screen panel show everything" is
    /// invisible in a screenshot (the screenshot is taken at the size it produced) and
    /// obvious in an assertion.
    static func fillScreenPageSize(visibleFrame: CGSize, maxItemsPerPage: Int) -> Int {
        let columns = max(1, min(4, Int((visibleFrame.width - padding * 2) / denseColumnStride)))
        return fittedPageSize(
            maxItemsPerPage: maxItemsPerPage,
            columns: columns,
            panelHeight: visibleFrame.height,
            cardCount: 2,
            headingCount: 2
        )
    }

    /// How many rows one column can show in a panel of `panelHeight`, after the header,
    /// the footer, the list's padding, the card chrome and the gaps have taken their share.
    ///
    /// Integer floor with a small epsilon: a height that is exactly N rows must give N, not
    /// N−1, on a scaled display where `available / rowHeight` computes 29.9999. One row
    /// always remains — a panel is never allowed to show zero menu items.
    static func rowsPerColumn(
        panelHeight: CGFloat,
        cardCount: Int,
        headingCount: Int
    ) -> Int {
        let cards = max(1, cardCount)
        let headings = max(0, headingCount)
        let groupHeaders = CGFloat(headings) * groupHeaderHeight
        let cardChrome = CGFloat(cards) * (cardVerticalInset * 2)
            + (headings > 0 ? cardRuleHeight : 0)
        let gaps = CGFloat(max(0, cards - 1)) * cardGap
        let available = panelHeight - chromeHeight - groupHeaders - cardChrome - gaps
        let rows = Int(floor(available / rowHeight + 0.0001))
        return max(1, rows)
    }

    /// The rows one page may hold: the user's setting is an upper bound, the geometry is
    /// the other. A page of 60 rows in a 720 pt window would be cut by the footer, so the
    /// geometry wins — the same reason a single row is still guaranteed.
    static func fittedPageSize(
        maxItemsPerPage: Int,
        columns: Int,
        panelHeight: CGFloat,
        cardCount: Int,
        headingCount: Int
    ) -> Int {
        let capacity = rowsPerColumn(
            panelHeight: panelHeight,
            cardCount: cardCount,
            headingCount: headingCount
        ) * max(1, columns)
        return max(1, min(max(1, maxItemsPerPage), capacity))
    }

    /// Cheat-sheet density: one column per grid stride, capped at four. The stride includes
    /// the inter-column gap so the count and the natural width use the same arithmetic.
    static func columns(forWidth width: CGFloat) -> Int {
        let content = width - padding * 2 + columnSpacing
        let stride = columnWidth + columnSpacing
        return max(1, min(4, Int(content / stride)))
    }

    static func size(for state: PanelState, settings: AppSettingsSnapshot) -> CGSize {
        let columns = max(1, min(settings.columnCount, 4))
        let width = CGFloat(columns) * columnWidth
            + CGFloat(max(0, columns - 1)) * columnSpacing
            + padding * 2
        return size(for: state, settings: settings, width: width)
    }

    static func size(for state: PanelState, settings: AppSettingsSnapshot, width: CGFloat) -> CGSize {
        let columns = max(1, min(settings.columnCount, columns(forWidth: width)))
        var onScreenRows = 0
        for group in state.groups {
            onScreenRows += max(1, Int(ceil(Double(group.rows.count) / Double(columns))))
        }
        if state.groups.isEmpty { onScreenRows = 1 }

        // The frame is sized for the widest list of the session, not for the page on
        // screen: pressing a modifier narrows the list, and a window that changed height
        // with it read as the panel jumping. Taking the larger of the two keeps the frame
        // stable in the normal case and guarantees it always fits what is drawn.
        let budgetRows = Int(ceil(Double(state.rowBudget) / Double(columns)))
        let visualRows = max(onScreenRows, budgetRows)

        // A group with an empty title is the flat shortcut list: it draws no heading, so it
        // must not reserve one either. The heading count follows the same rule as the rows
        // — a heading the widest list draws stays reserved after narrowing removes it.
        let titledGroups = state.groups.filter { !$0.title.isEmpty }
        let headings = max(titledGroups.count, state.headingBudget)
        let groupHeaders = CGFloat(headings) * groupHeaderHeight
        // Every section is a card: it carries its own vertical insets, and the cards are
        // separated by `cardGap`. Counted from the groups actually drawn, not from the
        // headings — an untitled card still costs its padding and still needs the gap.
        let cardChrome = CGFloat(state.groups.count)
            * (cardVerticalInset * 2 + (titledGroups.isEmpty ? 0 : cardRuleHeight))
        let gaps = CGFloat(max(0, state.groups.count - 1)) * cardGap

        var height = chromeHeight + groupHeaders + cardChrome
            + CGFloat(visualRows) * rowHeight + gaps
        height = min(max(height, minPanelHeight), maxPanelHeight)
        return CGSize(width: max(width, 300), height: height)
    }
}
