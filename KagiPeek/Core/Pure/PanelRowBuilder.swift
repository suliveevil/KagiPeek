import Foundation

/// Builds the panel's rows and groups.
///
/// The panel used to have two rebuild paths — the shortcut list and an inline filter — that
/// constructed rows separately and drifted apart. The filter is gone; what it taught is kept:
/// one builder, and the rows' shape decided by explicit spec fields.
enum PanelRowBuilder {
    struct Spec {
        var id: String
        /// The chord already split into glyphs (see `KeyFormatter.segments`).
        var keySegments: [KeyFormatter.Segment]
        var title: String
        /// Menu-bar path shown as a note beside the title; empty when a section heading
        /// already says it.
        var note: String = ""
        /// An empty title means "no heading": the app's section is one flat list ordered by
        /// the shortcut itself, while the system section starts at its own heading.
        var groupTitle: String
        var isGroup = false
        var isEnabled = true
        var hasConflict = false
        var isHighlighted = false
        var isCompleted = false
        var isFavorite = false
    }

    static func build(_ specs: [Spec]) -> (groups: [PanelGroup], flatRowIDs: [String]) {
        var groups: [PanelGroup] = []
        var indexOfGroup: [String: Int] = [:]
        var flatRowIDs: [String] = []

        for spec in specs {
            let row = PanelRow(
                id: spec.id,
                keySegments: spec.keySegments,
                title: spec.title,
                note: spec.note,
                isGroup: spec.isGroup,
                isEnabled: spec.isEnabled,
                hasConflict: spec.hasConflict,
                index: flatRowIDs.count,
                isHighlighted: spec.isHighlighted,
                isCompleted: spec.isCompleted,
                isFavorite: spec.isFavorite
            )
            flatRowIDs.append(spec.id)

            if let index = indexOfGroup[spec.groupTitle] {
                let existing = groups[index]
                groups[index] = PanelGroup(id: existing.id, title: existing.title, rows: existing.rows + [row])
            } else {
                indexOfGroup[spec.groupTitle] = groups.count
                groups.append(PanelGroup(id: spec.groupTitle, title: spec.groupTitle, rows: [row]))
            }
        }
        return (groups, flatRowIDs)
    }
}
