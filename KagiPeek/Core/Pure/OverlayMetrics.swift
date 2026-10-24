import CoreGraphics
import Foundation

/// Layout maths shared by the panel controller (window sizing) and the SwiftUI view so the
/// two can never disagree.
///
/// Deliberately free of AppKit and SwiftUI: the height the panel window takes is a number
/// that can be asserted in a test, and "does narrowing resize the window" is exactly the
/// kind of regression that is invisible in a screenshot but obvious in an assertion.
enum OverlayMetrics {
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
    /// Vertical padding (10×2) + header (56 + 6) + footer (34) + 2pt of slack.
    static let chromeHeight: CGFloat = 20 + 62 + 34 + 2

    /// Gap between adjacent grid columns, kept in sync with `RowLayout.columnSpacing`.
    static let columnSpacing: CGFloat = 18

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
