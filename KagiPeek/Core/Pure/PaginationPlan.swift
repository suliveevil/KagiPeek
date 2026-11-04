import Foundation

/// How a page key moves through a list that has one page or many.
///
/// The panel used to stop at the ends: "next" on the last page and "previous" on the first
/// were no-ops, which read as a broken key because nothing on screen reacted. The list is
/// finite and the keys are the only way around it, so the page index loops. A one-page list
/// is the exception: there is nowhere to move, and pretending to move would flash the panel
/// for nothing.
nonisolated enum PaginationPlan {
    /// A page index that is always inside the list, so a count that shrank can never leave
    /// the user on a page that no longer exists.
    static func clamped(_ index: Int, pageCount: Int) -> Int {
        let count = max(1, pageCount)
        return min(max(0, index), count - 1)
    }

    /// Next page, wrapping from the last to the first.
    static func nextPage(from index: Int, pageCount: Int) -> Int {
        let count = max(1, pageCount)
        let current = clamped(index, pageCount: count)
        return current + 1 >= count ? 0 : current + 1
    }

    /// Previous page, wrapping from the first to the last.
    static func previousPage(from index: Int, pageCount: Int) -> Int {
        let count = max(1, pageCount)
        let current = clamped(index, pageCount: count)
        return current <= 0 ? count - 1 : current - 1
    }

    /// Whether the key actually moved the page. A single page never moves, and the caller
    /// uses this to skip the rebuild — no flash, no reorder, no "page 1/1" log line.
    static func moved(from index: Int, to target: Int, pageCount: Int) -> Bool {
        clamped(index, pageCount: pageCount) != clamped(target, pageCount: pageCount)
    }
}
