import Foundation

/// Which children of a menu are commands, and which are content.
///
/// A menu bar mixes both. `Edit` holds commands, while Safari's `History` menu also lists
/// every visited page and its `Bookmarks` menu every saved link — and those lists are not
/// flat: the pages sit under a per-day submenu and the links under folder submenus. Measured
/// on a real Safari: 2 184 rows, of which 1 311 at depth 3 with **no** keyboard shortcut at
/// all. Walking them as commands flooded the panel, and because the walk hit the 2 500-item
/// cap inside `Bookmarks`, the `Window` and `Help` menus were never read.
///
/// The tell is a shortcut sample. A command menu has shortcuts in it; a page or link list
/// has none, however deep it sits. Reading eight children's shortcuts is cheap enough to do
/// per node, and it separates the two cleanly: on that Safari scan it took the catalog from
/// 2 184 rows to 144, keeping every real command (including the ones without a shortcut).
enum MenuContentPolicy {
    /// A flat menu with more children than this is a list of data, whatever its sample says.
    /// Real command menus peak around 176 (CotEditor `格式`); the data menus were 1 396 and
    /// 2 344 before nesting was taken into account.
    static let maxCommandChildren = 200

    /// In a menu that is data, the commands sit at the top ("Show All History", "Add
    /// Bookmark…"); the rest is the list.
    static let commandPrefix = 48

    /// How many children to read shortcuts from before deciding a node's nature.
    static let sampleLimit = 8

    /// Below this many children there is nothing to tell apart: a fourteen-entry app menu
    /// with a single shortcut is still a command menu (Safari's own menu is one).
    static let sampleThreshold = 12

    /// Menus whose children are the user's data whatever they look like: a browser's
    /// bookmarks and history list pages and saved links, not commands. Matching the name is
    /// exact where the shortcut sample is only a guess — `Bookmarks` opens with real
    /// commands (⌘D, ⌥⌘B), so the sample finds shortcuts there and would keep the fifty
    /// links that follow them.
    ///
    /// The app ships two languages, so the table holds exactly those two spellings. An app
    /// speaking a third one still gets the sample rule, which drops the bulk of a nested
    /// list even though it cannot catch a list that starts with commands.
    static let dataMenuTitles: Set<String> = [
        "history", "bookmarks", "reading list", "downloads",
        "历史记录", "书签", "阅读列表", "下载"
    ]

    /// Whether a top-level menu's title names a list of the user's data.
    ///
    /// Normalised for the spellings apps actually use: case, a trailing ellipsis, and the
    /// spaces some languages put around the word.
    static func isDataMenu(title: String) -> Bool {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "…..."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return dataMenuTitles.contains(normalized)
    }

    /// A menu known by name to be data: keep the rows that carry a shortcut (its commands),
    /// drop the list. An oversized one is only read up to the command prefix.
    static func decideDataMenuByTitle(childCount: Int) -> Decision {
        let count = max(0, childCount)
        return Decision(
            looksLikeContent: true,
            childrenToVisit: count > maxCommandChildren ? min(count, commandPrefix) : count,
            keepsShortcutlessChildren: false
        )
    }

    struct Decision: Equatable, Sendable {
        var looksLikeContent: Bool
        /// How many children of this node to read at all. Zero means the node is data: not
        /// one of its children can become a row.
        var childrenToVisit: Int
        /// Whether a child without a keyboard shortcut is still a command worth a row.
        var keepsShortcutlessChildren: Bool

        var skipsNodeEntirely: Bool { childrenToVisit == 0 && looksLikeContent }
    }

    /// A top-level menu that is not known by name. Only its size can condemn it: an app's
    /// command menus stay far under `maxCommandChildren`, and a verdict here never drops the
    /// menu — it just stops reading past the command prefix.
    static func decideOpenMenu(childCount: Int) -> Decision {
        let count = max(0, childCount)
        guard count > maxCommandChildren else {
            return Decision(looksLikeContent: false, childrenToVisit: count, keepsShortcutlessChildren: true)
        }
        return Decision(
            looksLikeContent: true,
            childrenToVisit: min(count, commandPrefix),
            keepsShortcutlessChildren: false
        )
    }

    /// A submenu: a command submenu, or a folder of bookmarks / one day of history.
    ///
    /// - Parameter sampledShortcut: whether any of the first `sampleLimit` children carries a
    ///   keyboard shortcut. `nil` when no sample was taken because the node is too small.
    static func decideSubmenu(childCount: Int, sampledShortcut: Bool?) -> Decision {
        let count = max(0, childCount)
        if count > maxCommandChildren {
            return Decision(
                looksLikeContent: true,
                childrenToVisit: min(count, commandPrefix),
                keepsShortcutlessChildren: false
            )
        }
        if count >= sampleThreshold, sampledShortcut == false {
            // Nothing in it can be a row: skipping the node saves the walk as well.
            return Decision(looksLikeContent: true, childrenToVisit: 0, keepsShortcutlessChildren: false)
        }
        return Decision(looksLikeContent: false, childrenToVisit: count, keepsShortcutlessChildren: true)
    }

    /// Whether `childCount` children are enough to be worth sampling.
    static func needsSample(childCount: Int) -> Bool {
        max(0, childCount) >= sampleThreshold
    }
}
