import Foundation

/// A static best guess at which of several bindings on one combo actually receives it.
///
/// This answers the question everyone asks after seeing a conflict: "fine, but who
/// wins?" It reasons purely from `ShortcutLayer`, which means it is right often and
/// honest when it cannot be. Where the layers tie, it says so rather than picking a
/// name and hoping, because the tiebreaker is registration order and nothing on disk
/// records that.
///
/// The ids are all a verdict carries: `BindingItem` is `Hashable` but every copy of it
/// is a different value across a rescan, so holding one here would go stale the moment
/// the user switches apps.
nonisolated enum LayerVerdict: Equatable, Sendable {
    /// One binding sits strictly lower in the event stack than every other.
    case winner(itemID: String, layer: ShortcutLayer)
    /// Several bindings share the lowest layer, so registration order decides.
    case tied(itemIDs: [String], layer: ShortcutLayer)
    /// Every binding is a menu item, so macOS matches them in menu order and the
    /// frontmost app is the only one in play at all.
    case menuOrder

    static func evaluate(_ items: [BindingItem]) -> LayerVerdict? {
        guard !items.isEmpty else { return nil }

        let layered = items.map { (item: $0, layer: ShortcutLayer.classify($0)) }
        guard let lowest = layered.map(\.layer).min() else { return nil }

        // Menu items are the top of the stack. If that is the lowest layer present then
        // nothing global is involved and there is no stack to reason about: the app in
        // front decides by walking its own menus.
        guard lowest != .menuItem else { return .menuOrder }

        let contenders = layered.filter { $0.layer == lowest }.map(\.item)
        if contenders.count == 1, let only = contenders.first {
            return .winner(itemID: only.id, layer: lowest)
        }
        return .tied(itemIDs: contenders.map(\.id), layer: lowest)
    }

    /// The item to mark in the list, when there is a single clear favourite.
    var winningItemID: String? {
        if case .winner(let itemID, _) = self { return itemID }
        return nil
    }

    /// The layer the verdict was decided on, when the stack had anything to say.
    var layer: ShortcutLayer? {
        switch self {
        case .winner(_, let layer): return layer
        case .tied(_, let layer): return layer
        case .menuOrder: return .menuItem
        }
    }
}

/// What kind of clash this is — which two things want the same combo.
///
/// The old split was by severity: menu overlap / shadowed / definite. That answered "how bad"
/// and nothing else, and "definite" covered both "two tools I installed collide" and "macOS
/// and a tool collide" — two problems with completely different fixes. The label is now the
/// *pairing*, because that is what decides where the user has to go:
///
/// * a menu item blocked by macOS → System Settings → Keyboard → Shortcuts;
/// * a menu item blocked by a tool → that tool's config;
/// * two always-on sources → whichever of them sits lower, or registration order.
///
/// Severity is derived from the kind (menu-only < one always-on side < both sides), so the
/// sort order did not have to be sacrificed to get the better names.
nonisolated enum ConflictCategory: Int, Comparable, CaseIterable, Sendable {
    /// Only commands of one app overlap. macOS walks that app's menu in order; nothing is
    /// broken and nothing needs changing.
    case menuOrder = 0
    /// A macOS shortcut and an app menu item. The menu item can never fire.
    case systemShadow = 1
    /// A tool the user installed and an app menu item. Same effect, different fix.
    case toolShadow = 2
    /// One tool binding the same combo twice. Nothing to arbitrate: one of its own rules is
    /// dead, and the fix is inside that tool's config.
    case toolSelfOverlap = 3
    /// Two macOS shortcuts. Rare, but a real and separate thing to untangle.
    case systemVsSystem = 4
    /// A macOS shortcut and an installed tool, both always on.
    case systemVsTool = 5
    /// Two installed tools, both always on. Same layer means registration order decides.
    case toolVsTool = 6

    static func < (lhs: ConflictCategory, rhs: ConflictCategory) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Classifies a group of bindings that share one combo.
    static func classify(_ items: [BindingItem]) -> ConflictCategory {
        let layers = items.map { ShortcutLayer.classify($0) }
        let alwaysOn = layers.filter { $0.isAlwaysOn }
        guard !alwaysOn.isEmpty else { return .menuOrder }

        let systemCount = alwaysOn.filter { $0.isSystemLayer }.count
        let toolCount = alwaysOn.count - systemCount

        if alwaysOn.count == 1 {
            return systemCount == 1 ? .systemShadow : .toolShadow
        }
        // Same tool on both sides: "two tools collide" would be a misleading label for a
        // configuration with one tool and two rules.
        let tools = items
            .filter { ShortcutLayer.classify($0).isAlwaysOn }
            .compactMap(\.configTool)
        if tools.count == alwaysOn.count, Set(tools).count == 1 {
            return .toolSelfOverlap
        }
        if toolCount == 0 { return .systemVsSystem }
        if systemCount == 0 { return .toolVsTool }
        return .systemVsTool
    }

    var labelKey: L10nKey {
        switch self {
        case .menuOrder: return .conflictCategoryMenuOrder
        case .systemShadow: return .conflictCategorySystemShadow
        case .toolShadow: return .conflictCategoryToolShadow
        case .toolSelfOverlap: return .conflictCategoryToolSelfOverlap
        case .systemVsSystem: return .conflictCategorySystemVsSystem
        case .systemVsTool: return .conflictCategorySystemVsTool
        case .toolVsTool: return .conflictCategoryToolVsTool
        }
    }

    /// Why this category is the one being shown, in one sentence — and where the fix lives.
    var explanationKey: L10nKey {
        switch self {
        case .menuOrder: return .conflictCategoryMenuOrderExplanation
        case .systemShadow: return .conflictCategorySystemShadowExplanation
        case .toolShadow: return .conflictCategoryToolShadowExplanation
        case .toolSelfOverlap: return .conflictCategoryToolSelfOverlapExplanation
        case .systemVsSystem: return .conflictCategorySystemVsSystemExplanation
        case .systemVsTool: return .conflictCategorySystemVsToolExplanation
        case .toolVsTool: return .conflictCategoryToolVsToolExplanation
        }
    }

    /// Whether anything always-on is involved, which is what makes a clash bite
    /// regardless of which app happens to be in front.
    var isRealConflict: Bool { self != .menuOrder }

    /// Both sides stay on all the time, so the clash happens in every app.
    var isAlwaysOnPair: Bool { rawValue >= ConflictCategory.toolSelfOverlap.rawValue }
}

/// Pure value data built and sorted by the nonisolated detector.
nonisolated struct BindingConflict: Identifiable, Equatable, Sendable {
    let id: String
    let chordKey: String
    let items: [BindingItem]

    /// What kind of clash this is, derived from the members rather than stored, so it
    /// cannot drift out of step with the items it describes.
    var category: ConflictCategory { ConflictCategory.classify(items) }

    /// Who most likely receives the combo, or why that cannot be said.
    var verdict: LayerVerdict? { LayerVerdict.evaluate(items) }

    /// How many distinct owners claim the combo.
    ///
    /// Distinct owners, not distinct items: one tool can bind the same combo twice, and
    /// two menu items of one app are one owner. Universal boilerplate shared by many
    /// owners is weaker evidence than a combo two owners happened to pick.
    var ownerCount: Int {
        Set(items.map { $0.configTool?.rawValue ?? $0.appBundleID ?? "*" }).count
    }

    /// The always-on members, which are the ones worth naming first.
    var alwaysOnItems: [BindingItem] {
        items.filter { ShortcutLayer.classify($0).isAlwaysOn }
    }

    /// Apps that take part in this clash.
    ///
    /// A clash between a menu item and a system shortcut belongs to that app: the app is the
    /// side the user can act on, and it is what they were looking at when they asked. A clash
    /// with no app involved at all is global — it bites everywhere, so listing it under one
    /// app would be a lie.
    var appBundleIDs: Set<String> {
        Set(items.compactMap(\.appBundleID))
    }

    var isGlobalOnly: Bool { appBundleIDs.isEmpty }

    /// A copy whose `id` survives being listed beside the same chord from another app.
    ///
    /// One chord can clash in several apps at once; without the owner in the id, SwiftUI
    /// would treat those rows as one and draw whichever it saw first.
    func scoped(to owner: String?) -> BindingConflict {
        BindingConflict(id: "\(owner ?? "global")|\(id)", chordKey: chordKey, items: items)
    }
}

/// Which owner the conflict list is narrowed to.
///
/// Independent of the type filter: "show me the ones a tool is blocking" and "show me the
/// ones that involve Safari" are two questions.
enum ConflictOwnerFilter: Hashable, Sendable, Identifiable {
    case all
    case global
    case app(String)

    var id: String {
        switch self {
        case .all: return "*"
        case .global: return "-"
        case .app(let bundleID): return bundleID
        }
    }

    /// Label for the two non-app cases. An app filter is labelled with the app's name, which
    /// only the UI can resolve.
    var labelKey: L10nKey? {
        switch self {
        case .all: return .conflictOwnerAll
        case .global: return .conflictOwnerGlobal
        case .app: return nil
        }
    }

    func matches(_ conflict: BindingConflict) -> Bool {
        switch self {
        case .all: return true
        case .global: return conflict.isGlobalOnly
        case .app(let bundleID): return conflict.appBundleIDs.contains(bundleID)
        }
    }
}

/// One row of the type filter: a kind of clash and how many findings it has.
struct ConflictTypeOption: Identifiable, Equatable, Sendable {
    let category: ConflictCategory
    let count: Int

    var id: Int { category.rawValue }
}

/// What the findings list shows: a kind of clash, an owner, or both.
///
/// These are two independent questions — "only the ones a tool is blocking" and "only the
/// ones that involve Safari" — and the page offers both rather than making the user choose
/// which one to express. Narrowing by *kind* replaces the old severity switch: severity was
/// only ever a coarse grouping of the same kinds, and the kinds are what the reader acts on.
struct ConflictFilter: Equatable, Sendable {
    var category: ConflictCategory?
    var owner: ConflictOwnerFilter = .all

    func matches(_ conflict: BindingConflict) -> Bool {
        if let category, conflict.category != category { return false }
        return owner.matches(conflict)
    }
}

/// Finds chords that more than one entry claims, and says how much each one matters.
///
/// Nonisolated: pure set logic over value types, run from a detached task by the engine
/// under the app target's default-MainActor isolation.
nonisolated enum ConflictDetector {
    /// `external` entries (system-wide hotkeys and third-party config bindings) are
    /// considered for clashes but are not part of the app's own list.
    static func conflicts(
        in items: [BindingItem],
        external: [BindingItem] = []
    ) -> [BindingConflict] {
        var grouped: [String: [BindingItem]] = [:]
        for item in items + external where item.chord.steps.contains(where: { $0.key != nil }) {
            grouped[item.chord.cacheKey, default: []].append(item)
        }

        var conflicts: [BindingConflict] = []
        for (key, bucket) in grouped where bucket.count > 1 {
            // Identical entries (same title/group/source) are duplicates, not conflicts.
            var titles = Set<String>()
            var seenIDs = Set<String>()
            var unique: [BindingItem] = []
            for item in bucket {
                titles.insert(item.title)
                if seenIDs.insert(item.id).inserted {
                    unique.append(item)
                }
            }
            guard titles.count > 1 else { continue }
            conflicts.append(
                BindingConflict(
                    id: key,
                    chordKey: key,
                    items: unique.sorted { lhs, rhs in
                        let left = ShortcutLayer.classify(lhs).rawValue
                        let right = ShortcutLayer.classify(rhs).rawValue
                        if left != right { return left < right }
                        return lhs.title < rhs.title
                    }
                )
            )
        }
        // Severity first, then the combos the most owners agree on. A clash that bites
        // outranks a menu overlap no matter how many menu items share the combo.
        return conflicts.sorted { lhs, rhs in
            if lhs.category != rhs.category { return lhs.category > rhs.category }
            if lhs.ownerCount != rhs.ownerCount { return lhs.ownerCount > rhs.ownerCount }
            return lhs.chordKey < rhs.chordKey
        }
    }

    static func conflictIDs(in items: [BindingItem], external: [BindingItem] = []) -> Set<String> {
        Set(conflicts(in: items, external: external).flatMap { $0.items.map(\.id) })
    }
}
