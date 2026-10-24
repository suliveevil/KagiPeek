import Foundation

/// How much vertical space the panel should reserve for its widest list.
///
/// The budget is a session-stability device, not a second pagination rule: a narrow list
/// keeps the frame of the widest list, but an empty or short list must not open a full page
/// of blank space.
enum PanelBudget {
    struct Allocation: Equatable, Sendable {
        var rows: Int
        var headings: Int
    }

    static func budget(totalRows: Int, pageSize: Int, headings: Int) -> Allocation {
        guard totalRows > 0, pageSize > 0 else { return Allocation(rows: 0, headings: 0) }
        return Allocation(rows: min(totalRows, pageSize), headings: max(0, headings))
    }
}
