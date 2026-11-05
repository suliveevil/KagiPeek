import Foundation

/// Which of the panel's sources a row came from.
///
/// The panel is three lists, never interleaved: the frontmost app's commands, the system's
/// hotkeys, then the shortcuts read out of each config tool's file. Each kind is a card of
/// its own, so a row has to know its section and not just "is it a system hotkey".
nonisolated enum PanelSectionID: Hashable, Sendable {
    /// The frontmost app's own menu commands.
    case app
    /// The system's own hotkeys.
    case system
    /// A third-party keyboard tool, read from its config file.
    case tool(ConfigTool)
}

/// One row of the panel's combined sequence, tagged with the section it belongs to.
nonisolated struct PanelEntry: Identifiable, Equatable, Sendable {
    let hit: PrefixHit
    let section: PanelSectionID

    var id: String { hit.id }
}

/// The panel's sections: the frontmost app's commands, the system's hotkeys, and one block
/// per config tool.
///
/// Rows inside a section keep the chord order they always had — `PanelOrdering` is unchanged —
/// and the sections never interleave: each block is whole before the next one starts. That is
/// also the boundary the panel draws a heading at, so the difference between the sources is
/// visible instead of implied.
///
/// Pagination runs over this combined sequence. A page belongs to whichever sections its rows
/// came from; the order only has to be fixed, which is what the callers below guarantee.
nonisolated enum PanelSections {
    /// Wraps hotkeys as panel rows.
    ///
    /// They are single chords with no prefix to complete, so `nextKey` is nil and
    /// `remainingSteps` is zero — the same shape a finished shortcut has.
    static func hits(for items: [BindingItem]) -> [PrefixHit] {
        items.map { item in
            PrefixHit(item: item, nextKey: nil, remainingSteps: 0, relation: .exact)
        }
    }

    /// Concatenates the sections in the order given. No sorting, no de-duplication: the
    /// caller decides the order, and a row that exists in two sources stays two rows.
    static func combine(_ sections: [(section: PanelSectionID, hits: [PrefixHit])]) -> [PanelEntry] {
        sections.flatMap { pair in
            pair.hits.map { PanelEntry(hit: $0, section: pair.section) }
        }
    }

    /// The two-source form, kept for callers that have no tool rows yet.
    static func combine(app: [PrefixHit], system: [PrefixHit]) -> [PanelEntry] {
        combine([(section: .app, hits: app), (section: .system, hits: system)])
    }

    /// The panel's fixed source order: App, then system, then one block per tool in the
    /// order supplied.
    static func combine(
        app: [PrefixHit],
        system: [PrefixHit],
        tool: [(ConfigTool, [PrefixHit])]
    ) -> [PanelEntry] {
        let fixed: [(section: PanelSectionID, hits: [PrefixHit])] = [
            (section: .app, hits: app),
            (section: .system, hits: system)
        ]
        let blocks: [(section: PanelSectionID, hits: [PrefixHit])] = tool.map {
            (section: PanelSectionID.tool($0.0), hits: $0.1)
        }
        return combine(fixed + blocks)
    }

    /// The section order the panel always draws, as one list.
    ///
    /// Tools arrive already ordered by the caller (`ConfigTool.allCases` in the session), so
    /// this function does not sort: it only states that the app comes first and the system
    /// second, before any tool.
    static func sectionOrder(tool: [ConfigTool] = []) -> [PanelSectionID] {
        [.app, .system] + tool.map(PanelSectionID.tool)
    }

    /// The rows the panel actually walks.
    ///
    /// Folded, the tool blocks leave the sequence — they still draw a titled card, but no
    /// rows — so their counts have to be taken from the unfiltered list (see `counts(in:)`).
    static func visible(_ entries: [PanelEntry], includeToolSection: Bool) -> [PanelEntry] {
        guard !includeToolSection else { return entries }
        return entries.filter { entry in
            if case .tool = entry.section { return false }
            return true
        }
    }

    /// How many rows each section contributes. Tools are counted one by one, never merged
    /// into the app's total.
    static func counts(in entries: [PanelEntry]) -> [PanelSectionID: Int] {
        var counts: [PanelSectionID: Int] = [:]
        for entry in entries {
            counts[entry.section, default: 0] += 1
        }
        return counts
    }

    /// How many section blocks these counts make when all tools are treated as one.
    ///
    /// Not the panel's card count: every tool draws its own card, which is what
    /// `cardAndHeadingBudget` counts and what page capacity must reserve.
    static func nonEmptySectionCount(appCount: Int, systemCount: Int, toolCount: Int) -> Int {
        1 + (systemCount > 0 ? 1 : 0) + (toolCount > 0 ? 1 : 0)
    }

    /// How many cards and headings the panel reserves for these sources.
    ///
    /// The app's card is always drawn, even when the app has no rows — that is the card the
    /// title bar's name belongs to. The system card and every tool card exist when they have
    /// rows: a folded tool still renders a titled card, so a non-empty tool counts. Tools are
    /// counted one by one — up to six — because each is its own card; treating them as one
    /// block is what let a page reserve three cards while drawing eight.
    ///
    /// `appHeading` is false in chord order, where the app's card is headed by the title bar
    /// instead of a heading row inside the list.
    static func cardAndHeadingBudget(
        systemCount: Int,
        toolCounts: [Int],
        appHeading: Bool
    ) -> (cards: Int, headings: Int) {
        let toolCards = toolCounts.filter { $0 > 0 }.count
        let cards = 1 + (systemCount > 0 ? 1 : 0) + toolCards
        let headings = (appHeading ? 1 : 0) + (systemCount > 0 ? 1 : 0) + toolCards
        return (cards, headings)
    }

    /// The index of the first row that is not an App row, for tests and for a caller that
    /// wants the boundary without walking the list.
    ///
    /// An empty system section does not move the boundary: it points at the first tool row
    /// instead, because the system section draws nothing when it has no rows.
    static func boundary(in entries: [PanelEntry]) -> Int? {
        entries.firstIndex { entry in
            if case .app = entry.section { return false }
            return true
        }
    }
}
