import Foundation

/// One row of the panel's combined sequence, tagged with the section it belongs to.
struct PanelEntry: Identifiable, Equatable, Sendable {
    let hit: PrefixHit
    /// True for the system's own hotkeys, which form the second section.
    let isSystem: Bool

    var id: String { hit.id }
}

/// The panel's two sections: the frontmost app's commands, then the system's hotkeys.
///
/// Rows inside a section keep the chord order they always had — `PanelOrdering` is unchanged —
/// and the sections never interleave: the app's section comes first, in full, and the system
/// section starts after it. That is also the boundary the panel draws a heading at, so the
/// order difference between the two sections is visible instead of implied.
///
/// Pagination runs over this combined sequence. The boundary is therefore crossed exactly once,
/// at the end of the app's list: a page either belongs to the app's section, contains the
/// boundary, or belongs to the system's.
enum PanelSections {
    /// Wraps system hotkeys as panel rows.
    ///
    /// They are single chords with no prefix to complete, so `nextKey` is nil and
    /// `remainingSteps` is zero — the same shape a finished shortcut has.
    static func hits(for items: [BindingItem]) -> [PrefixHit] {
        items.map { item in
            PrefixHit(item: item, nextKey: nil, remainingSteps: 0, relation: .exact)
        }
    }

    static func combine(app: [PrefixHit], system: [PrefixHit]) -> [PanelEntry] {
        app.map { PanelEntry(hit: $0, isSystem: false) }
            + system.map { PanelEntry(hit: $0, isSystem: true) }
    }

    /// Where the system section begins, for tests and for a caller that wants the boundary
    /// without walking the list.
    static func boundary(in entries: [PanelEntry]) -> Int? {
        entries.firstIndex { $0.isSystem }
    }
}
