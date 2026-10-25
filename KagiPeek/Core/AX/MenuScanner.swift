import AppKit
import ApplicationServices
import os

/// Why a scan produced what it did.
///
/// Menu-Bar-Search's `initState` (`.apiDisabled` / `.noValue`): an empty list and a read
/// that never happened look identical to the user, so the reason travels with the result
/// and the surfaces can say which one it was.
enum ScanState: Equatable, Sendable {
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
struct ScannedMenu {
    var items: [BindingItem]
    /// Binding id → actionable menu item, used by the search panel to press a command.
    var elements: [String: AXUIElement]
    var hasMenuBar: Bool
    var duration: TimeInterval
    var state: ScanState

    static let empty = ScannedMenu(items: [], elements: [:], hasMenuBar: false, duration: 0, state: .noMenus)
}

/// Reads every menu item of an app through the Accessibility API.
///
/// Runs on a background queue. AX calls can hang on a busy app, so the application element
/// gets a short messaging timeout and the walk is depth- and size-capped.
enum MenuScanner {
    private static let maxItems = 2_500
    private static let maxDepth = 7

    static func scan(pid: pid_t, bundleID: String?, showAppleMenu: Bool = false) -> ScannedMenu {
        let started = Date()
        // An untrusted process gets no AX values at all, which is indistinguishable from
        // "this app has no menus". Say which one it was instead of guessing.
        guard AXIsProcessTrusted() else {
            AppLog.scan.error("accessibility is not trusted; nothing can be read")
            Diag.error(.scan, "accessibility not trusted: no menu could be read (pid=\(pid), bundle=\(bundleID ?? "?"))")
            return ScannedMenu(items: [], elements: [:], hasMenuBar: false, duration: 0, state: .permissionDenied)
        }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.35)

        guard let menuBar = elementAttribute(kAXMenuBarAttribute, of: application) else {
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

        for (barIndex, menuBarItem) in children(of: menuBar).enumerated() {
            let topLevelTitle = stringAttribute(kAXTitleAttribute, of: menuBarItem) ?? ""
            // The Apple menu belongs to the system, not to the app in front: its items
            // ("About This Mac", "Sleep", …) are not this app's commands and would pad
            // every list with entries the user cannot act on meaningfully. The setting
            // turns it back on; the bar index stays counted either way, so menu paths —
            // and the disk cache keyed on them — do not shift when the setting flips.
            if topLevelTitle == "Apple", !showAppleMenu { continue }
            for (menuIndex, menu) in children(of: menuBarItem).enumerated() {
                // `History`, `Bookmarks` and their like are menus of data: they hold one row
                // per visited page or saved link. Read only the command prefix at the top of
                // such a menu, and treat everything else as content.
                let menuChildren = children(of: menu)
                // A menu whose name says it is a list of the user's data — a browser's
                // `Bookmarks` or `History` — is filtered by name. That is exact, where the
                // shortcut sample can only guess: `Bookmarks` opens with real commands
                // (⌘D, ⌥⌘B), so a sample finds shortcuts and would keep the fifty links
                // that follow them.
                // Top level decides by name, then by size — never by sampling. A top menu
                // is a command menu until it is known otherwise: `Develop` has 27 children
                // whose first ones carry no shortcut, and sampling would have dropped its
                // eighteen shortcutless commands.
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
        guard let menuBar = elementAttribute(kAXMenuBarAttribute, of: application) else { return nil }
        var element = menuBar
        for index in indices {
            let siblings = children(of: element)
            guard siblings.indices.contains(index) else { return nil }
            element = siblings[index]
        }
        if let expectingTitle {
            let title = (stringAttribute(kAXTitleAttribute, of: element) ?? "")
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

        let title = (stringAttribute(kAXTitleAttribute, of: element) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let submenu = children(of: element)
        let chord = shortcutChord(of: element)

        // A leaf with no shortcut is still a command the user can trigger — by pressing
        // the menu item itself — so it becomes a row with an empty chord instead of being
        // dropped. A *parent* item (it has children: "Open Recent", "Services") is not a
        // command and is only walked, unless it also carries a shortcut of its own.
        if !title.isEmpty, chord != nil || (keepsShortcutless && submenu.isEmpty) {
            let enabled = boolAttribute(kAXEnabledAttribute, of: element, fallback: true)
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
        let character = stringAttribute(kAXMenuItemCmdCharAttribute, of: element)
        let virtualKey = intAttribute(kAXMenuItemCmdVirtualKeyAttribute, of: element)
        let modifierBits = intAttribute(kAXMenuItemCmdModifiersAttribute, of: element) ?? 0

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

    // MARK: - AX plumbing

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        guard let value else { return nil }
        if CFGetTypeID(value) == CFNullGetTypeID() { return nil }
        return value
    }

    private static func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return value as? String
    }

    private static func intAttribute(_ name: String, of element: AXUIElement) -> Int? {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == CFNumberGetTypeID() else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }

    private static func boolAttribute(_ name: String, of element: AXUIElement, fallback: Bool) -> Bool {
        guard let value = attribute(name, of: element), CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return fallback
        }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(kAXChildrenAttribute, of: element), CFGetTypeID(value) == CFArrayGetTypeID() else {
            return []
        }
        let array = unsafeBitCast(value, to: CFArray.self)
        let count = CFArrayGetCount(array)
        guard count > 0 else { return [] }
        var result: [AXUIElement] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(array, index) else { continue }
            let child = unsafeBitCast(raw, to: CFTypeRef.self)
            guard CFGetTypeID(child) == AXUIElementGetTypeID() else { continue }
            result.append(unsafeBitCast(child, to: AXUIElement.self))
        }
        return result
    }
}
