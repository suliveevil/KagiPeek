import AppKit
import ApplicationServices
import os

/// Why a scan produced what it did.
///
/// Menu-Bar-Search's `initState` (`.apiDisabled` / `.noValue`): an empty list and a read
/// that never happened look identical to the user, so the reason travels with the result
/// and the surfaces can say which one it was.
nonisolated enum ScanState: Equatable, Sendable {
    /// Menus were read.
    case ok
    /// The app exposes no menu bar, or one without any command.
    case noMenus
    /// Accessibility is not trusted: nothing could be read at all, not even to find out
    /// whether the app has menus.
    case permissionDenied

    /// Stable spelling for the file log, so a grep for `state=` gives a countable answer
    /// instead of a Swift debug description.
    var diagnosticCode: String {
        switch self {
        case .ok: return "ok"
        case .noMenus: return "noMenus"
        case .permissionDenied: return "permissionDenied"
        }
    }
}

/// Result of walking one app's menu bar.
///
/// `nonisolated`: built on the background AX-walk queue and read back on the main actor.
/// The `AXUIElement` values are deliberately *not* `Sendable` — they are opaque CF types
/// that are only used by their owning scan — but marking the enclosing value nonisolated
/// is what lets the walk construct it without a main-actor hop.
nonisolated struct ScannedMenu {
    var items: [BindingItem]
    /// Binding id → actionable menu item, used by the search panel to press a command.
    var elements: [String: AXUIElement]
    var hasMenuBar: Bool
    var duration: TimeInterval
    var state: ScanState

    /// Computed, not stored: a `static let` of this non-`Sendable` value (it holds
    /// `AXUIElement`s) is global shared state under Swift 6. Nothing here is worth caching —
    /// it is two empty collections and four scalars, rebuilt on the few call sites that need
    /// an empty answer.
    static var empty: ScannedMenu {
        ScannedMenu(items: [], elements: [:], hasMenuBar: false, duration: 0, state: .noMenus)
    }
}

/// Reads every menu item of an app through the Accessibility API.
///
/// Runs on a background queue. AX calls can hang on a busy app, so the application element
/// gets a short messaging timeout and the walk is depth- and size-capped.
nonisolated enum MenuScanner {
    private static let maxItems = 2_500
    private static let maxDepth = 7

    static func scan(pid: pid_t, bundleID: String?, showAppleMenu: Bool = false) -> ScannedMenu {
        let started = Date()
        // An untrusted process gets no AX values at all, which is indistinguishable from
        // "this app has no menus". Say which one it was instead of guessing.
        guard AXIsProcessTrusted() else {
            Diag.error(.scan, "accessibility not trusted: no menu could be read (pid=\(pid), bundle=\(bundleID ?? "?"))")
            return ScannedMenu(items: [], elements: [:], hasMenuBar: false, duration: 0, state: .permissionDenied)
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.35)

        guard let menuBar = AXValueReader.element(kAXMenuBarAttribute, of: application) else {
            // "The app has no menu bar" and "the menu bar could not be read" look the same in
            // an empty panel; only one of them is a system limitation worth reporting.
            Diag.warning(.scan, "menu-bar attribute missing (pid=\(pid), bundle=\(bundleID ?? "?"))")
            return ScannedMenu(
                items: [], elements: [:], hasMenuBar: false,
                duration: Date().timeIntervalSince(started), state: .noMenus
            )
        }

        var items: [BindingItem] = []
        var elements: [String: AXUIElement] = [:]
        items.reserveCapacity(256)
        elements.reserveCapacity(256)

        for (barIndex, menuBarItem) in AXValueReader.children(of: menuBar).enumerated() {
            readMenuBarItem(
                menuBarItem,
                barIndex: barIndex,
                showAppleMenu: showAppleMenu,
                bundleID: bundleID,
                items: &items,
                elements: &elements
            )
        }

        if items.count >= maxItems {
            // A list that stops at a round number is a cap, not the app's menu; saying so
            // turns "half my shortcuts are missing" into an answer.
            Diag.warning(.scan, "truncated at maxItems=\(maxItems) (pid=\(pid), bundle=\(bundleID ?? "?"))")
        }

        return ScannedMenu(
            items: items,
            elements: elements,
            hasMenuBar: true,
            duration: Date().timeIntervalSince(started),
            state: items.isEmpty ? .noMenus : .ok
        )
    }

    /// One top-level title of the menu bar ("File", "Edit", "Apple") and the menus under it.
    ///
    /// The bar index stays counted even for a skipped Apple menu, so menu paths — and the
    /// disk cache keyed on them — do not shift when `showAppleMenu` flips.
    private static func readMenuBarItem(
        _ menuBarItem: AXUIElement,
        barIndex: Int,
        showAppleMenu: Bool,
        bundleID: String?,
        items: inout [BindingItem],
        elements: inout [String: AXUIElement]
    ) {
        let topLevelTitle = AXValueReader.string(kAXTitleAttribute, of: menuBarItem) ?? ""
        // The Apple menu belongs to the system, not to the app in front: its items ("About
        // This Mac", "Sleep", …) are not this app's commands and would pad every list with
        // entries the user cannot act on meaningfully. The setting turns it back on.
        if topLevelTitle == "Apple", !showAppleMenu { return }
        for (menuIndex, menu) in AXValueReader.children(of: menuBarItem).enumerated() {
            readMenu(
                menu,
                barIndex: barIndex,
                menuIndex: menuIndex,
                topLevelTitle: topLevelTitle,
                bundleID: bundleID,
                items: &items,
                elements: &elements
            )
        }
    }

    /// One dropdown and the commands inside it — the level where "is this a menu of data?"
    /// has to be answered before a single item is read.
    private static func readMenu(
        _ menu: AXUIElement,
        barIndex: Int,
        menuIndex: Int,
        topLevelTitle: String,
        bundleID: String?,
        items: inout [BindingItem],
        elements: inout [String: AXUIElement]
    ) {
        // `History`, `Bookmarks` and their like are menus of data: they hold one row per
        // visited page or saved link. Read only the command prefix at the top of such a
        // menu, and treat everything else as content.
        let menuChildren = AXValueReader.children(of: menu)
        // A menu whose name says it is a list of the user's data — a browser's `Bookmarks`
        // or `History` — is filtered by name. That is exact, where the shortcut sample can
        // only guess: `Bookmarks` opens with real commands (⌘D, ⌥⌘B), so a sample finds
        // shortcuts and would keep the fifty links that follow them.
        // Top level decides by name, then by size — never by sampling. A top menu is a
        // command menu until it is known otherwise: `Develop` has 27 children whose first
        // ones carry no shortcut, and sampling would have dropped its eighteen shortcutless
        // commands.
        let decision = MenuContentPolicy.isDataMenu(title: topLevelTitle)
            ? MenuContentPolicy.decideDataMenuByTitle(childCount: menuChildren.count)
            : MenuContentPolicy.decideOpenMenu(childCount: menuChildren.count)
        if decision.looksLikeContent {
            let menuTitle = Sanitizer.clamp(topLevelTitle.isEmpty ? "?" : topLevelTitle)
            Diag.info(.scan, """
                menu ·\(menuTitle) is a list of data (\(menuChildren.count) children), \
                reading \(decision.childrenToVisit), keeping shortcuts only
                """)
        }
        for (itemIndex, item) in menuChildren.prefix(decision.childrenToVisit).enumerated() {
            collect(
                item,
                path: topLevelTitle.isEmpty ? [] : [topLevelTitle],
                depth: 0,
                axPath: [barIndex, menuIndex, itemIndex],
                bundleID: bundleID,
                keepsShortcutless: decision.keepsShortcutlessChildren,
                items: &items,
                elements: &elements
            )
        }
    }

    // MARK: - Path resolution

    /// Resolves a row's stored menu path back to a live element.
    ///
    /// A snapshot restored from the disk cache carries rows but no elements — an
    /// AXUIElement cannot be serialised — so a press re-walks the path: a handful of AX
    /// calls, not a scan. The title is verified on the way out, because a menu that
    /// changed under the cache must resolve to nil rather than to whatever command took
    /// the row's place.
    static func element(atAxPath axPath: String, pid: pid_t, expectingTitle: String?) -> AXUIElement? {
        let indices = axPath.split(separator: ",").compactMap { Int($0) }
        guard !indices.isEmpty else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.35)
        guard let menuBar = AXValueReader.element(kAXMenuBarAttribute, of: application) else { return nil }
        var element = menuBar
        for index in indices {
            let siblings = AXValueReader.children(of: element)
            guard siblings.indices.contains(index) else { return nil }
            element = siblings[index]
        }
        if let expectingTitle {
            let title = (AXValueReader.string(kAXTitleAttribute, of: element) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard title == expectingTitle else { return nil }
        }
        return element
    }

    // MARK: - Walking

    /// Decides what a menu node is: a list of commands, or a list of data (browsing history
    /// by day, bookmarks by folder). The shortcut sample is what separates them — a command
    /// menu has shortcuts in it, a page or link list has none.
    ///
    /// Sampling costs at most `MenuContentPolicy.sampleLimit` shortcut reads, which is what
    /// makes skipping a 198-entry history day cheap instead of walking all of it.
    private static func submenuDecision(for children: [AXUIElement]) -> MenuContentPolicy.Decision {
        guard MenuContentPolicy.needsSample(childCount: children.count) else {
            return MenuContentPolicy.decideSubmenu(childCount: children.count, sampledShortcut: nil)
        }
        let hasShortcut = children.prefix(MenuContentPolicy.sampleLimit)
            .contains { shortcutChord(of: $0) != nil }
        return MenuContentPolicy.decideSubmenu(
            childCount: children.count,
            sampledShortcut: hasShortcut
        )
    }

    private static func collect(
        _ element: AXUIElement,
        path: [String],
        depth: Int,
        axPath: [Int],
        bundleID: String?,
        /// False once the walk is inside a menu of data: a shortcutless child there is a page
        /// or a bookmark, not a command.
        keepsShortcutless: Bool,
        items: inout [BindingItem],
        elements: inout [String: AXUIElement]
    ) {
        guard depth <= maxDepth, items.count < maxItems else { return }

        let title = (AXValueReader.string(kAXTitleAttribute, of: element) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let submenu = AXValueReader.children(of: element)
        let chord = shortcutChord(of: element)

        // A leaf with no shortcut is still a command the user can trigger — by pressing
        // the menu item itself — so it becomes a row with an empty chord instead of being
        // dropped. A *parent* item (it has children: "Open Recent", "Services") is not a
        // command and is only walked, unless it also carries a shortcut of its own.
        if !title.isEmpty, chord != nil || (keepsShortcutless && submenu.isEmpty) {
            let enabled = AXValueReader.bool(kAXEnabledAttribute, of: element, fallback: true)
            let binding = BindingItem(
                chord: chord ?? .empty,
                title: title,
                group: path,
                isEnabled: enabled,
                source: .menu,
                appBundleID: bundleID,
                axPath: axPath.map(String.init).joined(separator: ",")
            )
            items.append(binding)
            elements[binding.id] = element
        }

        // A data menu's submenus are folders of the same content (bookmark folders, history
        // by date): walking them costs an AX read per entry and yields nothing a shortcut
        // panel can use.
        guard !submenu.isEmpty, keepsShortcutless else { return }
        let childDecision = submenuDecision(for: submenu)
        if childDecision.looksLikeContent {
            let label = Sanitizer.clamp(title.isEmpty ? (path.last ?? "?") : title)
            Diag.info(.scan, """
                submenu ·\(label) looks like data (\(submenu.count) children),                 reading \(childDecision.childrenToVisit) of them
                """)
        }
        var nextPath = path
        if !title.isEmpty { nextPath.append(title) }
        for (index, child) in submenu.prefix(childDecision.childrenToVisit).enumerated() {
            collect(
                child,
                path: nextPath,
                depth: depth + 1,
                axPath: axPath + [index],
                bundleID: bundleID,
                keepsShortcutless: keepsShortcutless && childDecision.keepsShortcutlessChildren,
                items: &items,
                elements: &elements
            )
        }
    }

    // MARK: - Shortcut decoding

    private static func shortcutChord(of element: AXUIElement) -> KeyChord? {
        let character = AXValueReader.string(kAXMenuItemCmdCharAttribute, of: element)
        let virtualKey = AXValueReader.int(kAXMenuItemCmdVirtualKeyAttribute, of: element)
        let modifierBits = AXValueReader.int(kAXMenuItemCmdModifiersAttribute, of: element) ?? 0

        guard character != nil || virtualKey != nil else { return nil }

        var modifiers: ModifierSet = []
        if modifierBits & (1 << 0) != 0 { modifiers.insert(.shift) }
        if modifierBits & (1 << 1) != 0 { modifiers.insert(.option) }
        if modifierBits & (1 << 2) != 0 { modifiers.insert(.control) }
        // Command is implied unless the "no command" bit is set.
        if modifierBits & (1 << 3) == 0 { modifiers.insert(.command) }

        let characterToken = character.flatMap { KeyMapper.normalize(character: $0) }
        let physicalToken = virtualKey.flatMap { KeyMapper.token(forKeyCode: Int64($0)) }

        // With option/control the produced character is meaningless; the virtual key wins.
        let primary: KeyToken?
        if modifiers.contains(.option) || modifiers.contains(.control) {
            primary = physicalToken ?? characterToken
        } else {
            primary = characterToken ?? physicalToken
        }
        guard let primary else { return nil }

        var alternates: [KeyToken] = []
        if let other = (primary == characterToken ? physicalToken : characterToken), other != primary {
            alternates.append(other)
        }
        return KeyChord.combo(modifiers, primary, alternates: alternates)
    }

}
