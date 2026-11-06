import Foundation

/// Which config-tool cards show their rows.
///
/// Two inputs and one rule: the user's own fold choice per tool, and whether the panel is
/// narrowing. A folded card is fine while browsing — the count still says what is inside —
/// but a filter that matches one of those rows must show it, or the panel would report a
/// match the user cannot reach. The user's choice is read, never overwritten: clearing the
/// filter brings back exactly the cards they left open.
nonisolated enum ToolSectionFold {
    /// Whether this tool's rows belong to the sequence right now.
    ///
    /// Folded, the card keeps its frame and heading, and its rows leave the sequence. A
    /// filter in force opens every card, because a match behind a closed card is a dead end.
    static func isExpanded(tool: ConfigTool, expanded: Set<ConfigTool>, narrowing: Bool) -> Bool {
        narrowing || expanded.contains(tool)
    }

    /// The tool rows the panel may show, summed over the cards that are open.
    ///
    /// Used for the window's row budget: it has to cover the widest list this state can
    /// draw, and a card the filter just opened adds rows the folded budget never counted.
    static func visibleRowCount(
        toolCounts: [ConfigTool: Int],
        expanded: Set<ConfigTool>,
        narrowing: Bool
    ) -> Int {
        toolCounts.reduce(0) { total, pair in
            total + (isExpanded(tool: pair.key, expanded: expanded, narrowing: narrowing) ? pair.value : 0)
        }
    }
}
