import Foundation

/// Which order the panel lists its menu items in.
///
/// The choice is a display rule, not a ranking rule: both orders contain the same menu items
/// and keep the same within-section rules (favorites pinning, prefix narrowing). It lives in
/// pure code so the panel and the Shift-hint layer cannot disagree about "position N".
nonisolated enum PanelSortOrder: String, Codable, CaseIterable, Hashable, Sendable {
    /// The reference-card order: by the shortcut itself, ⌘ first. The default, and the
    /// behaviour every earlier build had.
    case byModifier
    /// Menu-bar order: every top-level menu stays together, in the order the menu bar shows
    /// them; inside a menu the shortcut order is unchanged.
    case byMenuGroup

    var titleKey: L10nKey {
        switch self {
        case .byModifier: return .panelOrderByModifier
        case .byMenuGroup: return .panelOrderByMenuGroup
        }
    }

    func sorted(_ items: [BindingItem], emphasizing modifiers: ModifierSet = []) -> [BindingItem] {
        sorted(items, by: { $0 }, emphasizing: modifiers)
    }

    /// Orders any values by the binding they carry, without copying them through an id map.
    /// The panel sorts hits this way: a hit carries the resolved prefix, so reconstructing the
    /// sequence by id would drop a duplicate binding (two menu items can share an id).
    func sorted<T>(
        _ values: [T],
        by item: (T) -> BindingItem,
        emphasizing modifiers: ModifierSet = []
    ) -> [T] {
        switch self {
        case .byModifier:
            return values.indices.sorted {
                PanelOrdering.areInIncreasingOrder(
                    item(values[$0]),
                    item(values[$1]),
                    emphasizing: modifiers
                )
            }.map { values[$0] }
        case .byMenuGroup:
            let items = values.map(item)
            return PanelOrdering.sortedIndicesByMenuGroup(items, emphasizing: modifiers).map { values[$0] }
        }
    }
}
