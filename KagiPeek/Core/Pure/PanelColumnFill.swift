import Foundation

/// How a page of rows is spread across the panel's columns.
///
/// The panel is a reference card, so a page is read **down** a column before moving to the
/// next one: with three columns, ⌘A…⌘K sit in the first column and ⌘L… continue in the
/// second. A `LazyVGrid` fills across instead (A B C on the first line, D E F on the second),
/// which turns a list ordered by the shortcut itself into a zig-zag, and makes ↓ move right
/// across the card while the rows are ordered by key.
///
/// Filling is **greedy to a measured capacity**, not even: each column takes as many rows as
/// the panel's height allows before the next column is touched. Dividing the page evenly
/// (`n / columns` rows each) leaves the card short of the space it has — a page of 50 rows in
/// three columns showed 17 rows a column instead of using the ~27 the window could show.
/// Only the last column ends up partly filled.
///
/// The panel's arrow keys walk `flatRowIDs` — the page's rows in order — so filling down the
/// columns makes the keyboard and the eye use the same sequence.
enum PanelColumnFill {
    /// Splits `rows` into up to `columns` contiguous runs, each holding at most `capacity`
    /// rows, filling the first column before the next.
    ///
    /// Flattening the result returns `rows` unchanged, so no row is dropped, duplicated or
    /// reordered. If `capacity` cannot hold the page across the columns it falls back to an
    /// even split — that is the old shape, and it is the shape that never loses a row.
    static func split<T>(_ rows: [T], into columns: Int, capacity: Int) -> [[T]] {
        let count = max(1, columns)
        guard !rows.isEmpty else { return Array(repeating: [], count: count) }
        let limit = max(1, capacity)
        guard rows.count <= count * limit else { return evenSplit(rows, into: count) }

        var result: [[T]] = []
        result.reserveCapacity(count)
        var start = 0
        for _ in 0..<count {
            let end = min(rows.count, start + limit)
            result.append(Array(rows[start..<end]))
            start = end
        }
        return result
    }

    private static func evenSplit<T>(_ rows: [T], into count: Int) -> [[T]] {
        let base = rows.count / count
        let remainder = rows.count % count
        var result: [[T]] = []
        result.reserveCapacity(count)
        var start = 0
        for index in 0..<count {
            let height = base + (index < remainder ? 1 : 0)
            result.append(Array(rows[start..<(start + height)]))
            start += height
        }
        return result
    }
}
