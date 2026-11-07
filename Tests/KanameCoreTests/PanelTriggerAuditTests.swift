import XCTest
@testable import KanameCore

/// The execution audit judges two independent paths for every row: pressing the chord and
/// activating the row. A row is red only when *both* are closed. These cases pin both halves
/// of the ⌥⌘M / ⌥⌘F bug (the filter claiming the last key, the router's narrower catalog),
/// and the false positive that started this change: a command with no shortcut is still a
/// command the user can click.
final class PanelTriggerAuditTests: XCTestCase {
    private static let inert = HotkeySpec(keyCode: 999, modifiers: [])

    private static let neutralSettings: AppSettingsSnapshot = {
        var settings = AppSettingsSnapshot()
        settings.panelHotkey = inert
        settings.searchHotkey = inert
        settings.switchHotkey = inert
        settings.runRowKey = inert
        settings.copyRowKey = inert
        return settings
    }()

    private func item(
        _ chord: KeyChord,
        _ title: String = "T",
        isEnabled: Bool = true,
        source: BindingSource = .menu,
        axPath: String? = nil
    ) -> BindingItem {
        BindingItem(
            chord: chord,
            title: title,
            group: ["Edit"],
            isEnabled: isEnabled,
            source: source,
            axPath: axPath
        )
    }

    private func context(
        filter: PanelFilter = PanelFilter(),
        held: ModifierSet = [],
        routingItems: [BindingItem] = [],
        pressableRowIDs: Set<String> = [],
        hasAccessibility: Bool = true,
        canResolveMenuPath: Bool = true
    ) -> PanelTriggerAudit.Context {
        var panel = PanelState()
        panel.isVisible = true
        panel.filter = filter
        panel.heldModifiers = held
        return PanelTriggerAudit.Context(
            phase: .active,
            settings: Self.neutralSettings,
            panel: panel,
            prefix: .empty,
            pending: PendingModifiers(),
            triggerPending: false,
            routingItems: routingItems,
            pressableRowIDs: pressableRowIDs,
            hasAccessibility: hasAccessibility,
            canResolveMenuPath: canResolveMenuPath
        )
    }

    private func narrowed(_ modifiers: ModifierSet...) -> PanelFilter {
        PanelFilter(tokens: modifiers.map { .modifier($0) })
    }

    private func verdict(
        for item: BindingItem,
        in result: PanelTriggerAudit.Result
    ) -> PanelTriggerAudit.Verdict? {
        result.verdict(forRowID: item.id)
    }

    // MARK: - A healthy row

    func testOrdinaryChordIsExecutable() {
        let copy = item(.combo([.command], KeyToken("c")), "Copy")
        let result = PanelTriggerAudit.audit(items: [copy], context: context(routingItems: [copy]))
        XCTAssertEqual(verdict(for: copy, in: result)?.status, .executable)
        XCTAssertNil(verdict(for: copy, in: result)?.shortcutBlocker)
        XCTAssertNil(verdict(for: copy, in: result)?.activationBlocker)
        XCTAssertTrue(result.unreachableRowIDs.isEmpty)
    }

    // MARK: - The chord is blocked, but the row still runs

    /// A bare-letter chord really does belong to the filter. That is a routing problem worth
    /// showing, but the row is still clickable: yellow, never "cannot be executed".
    func testFilterClaimedKeyIsYellowNotUnreachable() {
        let bare = item(.combo([], KeyToken("f")), "Bare F")
        let result = PanelTriggerAudit.audit(
            items: [bare],
            context: context(filter: narrowed(.control), routingItems: [bare])
        )
        XCTAssertEqual(verdict(for: bare, in: result)?.status, .shortcutBlocked)
        XCTAssertEqual(verdict(for: bare, in: result)?.shortcutBlocker, .claimedByFilter)
        XCTAssertNil(verdict(for: bare, in: result)?.activationBlocker)
        XCTAssertTrue(result.unreachableRowIDs.isEmpty)
    }

    /// The row came from `systemBindings` but the router only saw the app's menu catalog —
    /// exactly the ⌥⌘M case. Clicking a system row replays its chord, so the row is usable
    /// even though the router cannot find it.
    func testSystemHotkeyOutOfTheRoutingCatalogIsYellow() {
        let minimizeAll = item(
            .combo([.option, .command], KeyToken("m")),
            "Minimize All",
            source: .system
        )
        let result = PanelTriggerAudit.audit(items: [minimizeAll], context: context(routingItems: []))
        XCTAssertEqual(verdict(for: minimizeAll, in: result)?.status, .shortcutBlocked)
        XCTAssertEqual(verdict(for: minimizeAll, in: result)?.shortcutBlocker, .unresolvedByRouter)
        XCTAssertTrue(result.unreachableRowIDs.isEmpty)
    }

    /// With the router fed the same set the panel draws from, the system hotkey completes:
    /// an ordinary physical chord passes through to the front app.
    func testSystemHotkeyInTheRoutingCatalogIsExecutable() {
        let minimizeAll = item(
            .combo([.option, .command], KeyToken("m")),
            "Minimize All",
            source: .system
        )
        let result = PanelTriggerAudit.audit(
            items: [minimizeAll],
            context: context(routingItems: [minimizeAll])
        )
        XCTAssertEqual(verdict(for: minimizeAll, in: result)?.status, .executable)
        XCTAssertTrue(result.unreachableRowIDs.isEmpty)
    }

    /// Safari's Edit → Find ⌥⌘F while ⌥⌘ is narrowing the list: the last key carries the
    /// very modifiers in the filter, and must still be a chord rather than a search token.
    func testModifiedMenuShortcutStaysExecutableWhileNarrowing() {
        let find = item(.combo([.option, .command], KeyToken("f")), "Search with Bing")
        let result = PanelTriggerAudit.audit(
            items: [find],
            context: context(
                filter: narrowed(.option, .command),
                held: [.option, .command],
                routingItems: [find]
            )
        )
        XCTAssertEqual(verdict(for: find, in: result)?.status, .executable)
    }

    /// A panel-owned key (the bare slash that opens search) is a real reason the chord cannot
    /// be pressed; it is yellow, not red — clicking the row still runs it. A *modified* slash
    /// is an ordinary chord and must be green: `NavigationKey.isSlash` ignores ⌘/.
    func testPanelCapturedKeyIsYellow() {
        let slash = item(.combo([], KeyToken("/")), "Slash")
        let result = PanelTriggerAudit.audit(items: [slash], context: context(routingItems: [slash]))
        XCTAssertEqual(verdict(for: slash, in: result)?.status, .shortcutBlocked)
        XCTAssertEqual(verdict(for: slash, in: result)?.shortcutBlocker, .capturedByPanelKey)

        let modified = item(.combo([.command], KeyToken("/")), "Command Slash")
        let ordinary = PanelTriggerAudit.audit(
            items: [modified],
            context: context(routingItems: [modified])
        )
        XCTAssertEqual(verdict(for: modified, in: ordinary)?.status, .executable)
    }

    /// A chord that fails the shortcut check but whose row is still clickable must not be
    /// called unreachable even when the current filter hides it: the audit covers every row
    /// the panel could list, not just the page in front of the user.
    func testHiddenRowsStillGetAVerdict() {
        let hidden = item(.combo([.command], KeyToken("p")), "Print")
        let result = PanelTriggerAudit.audit(
            items: [hidden],
            context: context(filter: narrowed(.option), routingItems: [])
        )
        XCTAssertEqual(result.verdicts.count, 1)
        XCTAssertEqual(verdict(for: hidden, in: result)?.status, .shortcutBlocked)
        XCTAssertTrue(result.unreachableRowIDs.isEmpty)
    }

    // MARK: - Commands with no shortcut (the false positive)

    /// The regression this audit had to fix: a menu item with no chord is executed by
    /// pressing its Accessibility element. No chord is not a blocked chord — the row is
    /// green, not amber and certainly not red.
    func testChordLessCommandWithMenuPathIsExecutable() {
        let noShortcut = item(.empty, "Toggle Something", axPath: "2,0,5")
        let result = PanelTriggerAudit.audit(items: [noShortcut], context: context())
        XCTAssertEqual(verdict(for: noShortcut, in: result)?.status, .executable)
        XCTAssertEqual(verdict(for: noShortcut, in: result)?.shortcutBlocker, .noChord)
        XCTAssertNil(verdict(for: noShortcut, in: result)?.activationBlocker)
        XCTAssertTrue(result.unreachableRowIDs.isEmpty)
    }

    /// A live scan carries the element itself, so a row without an axPath is pressable too.
    func testChordLessCommandWithLiveElementIsExecutable() {
        let noShortcut = item(.empty, "Toggle Something")
        let result = PanelTriggerAudit.audit(
            items: [noShortcut],
            context: context(
                pressableRowIDs: [noShortcut.id],
                canResolveMenuPath: false
            )
        )
        XCTAssertEqual(verdict(for: noShortcut, in: result)?.status, .executable)
        XCTAssertTrue(result.unreachableRowIDs.isEmpty)
    }

    // MARK: - Both paths closed: red

    func testChordLessCommandWithoutElementOrPathIsUnreachable() {
        let orphan = item(.empty, "Orphan")
        let result = PanelTriggerAudit.audit(items: [orphan], context: context())
        XCTAssertEqual(verdict(for: orphan, in: result)?.status, .unreachable)
        XCTAssertEqual(verdict(for: orphan, in: result)?.shortcutBlocker, .noChord)
        XCTAssertEqual(verdict(for: orphan, in: result)?.activationBlocker, .noExecutionTarget)
        XCTAssertEqual(result.unreachableRowIDs, [orphan.id])
    }

    /// Without Accessibility trust there is no element to press; a chord-less row has
    /// nothing left to fall back on.
    func testChordLessCommandWithoutAccessibilityIsUnreachable() {
        let noShortcut = item(.empty, "Toggle Something", axPath: "2,0,5")
        let result = PanelTriggerAudit.audit(
            items: [noShortcut],
            context: context(hasAccessibility: false)
        )
        XCTAssertEqual(verdict(for: noShortcut, in: result)?.status, .unreachable)
        XCTAssertEqual(verdict(for: noShortcut, in: result)?.activationBlocker, .noExecutionTarget)
    }

    /// A disabled menu item refuses the click. With its chord also blocked, neither path
    /// runs it — the one combination that earns the red dot.
    func testDisabledRowWithBlockedChordIsUnreachable() {
        let disabled = item(.combo([.command], KeyToken("p")), "Print", isEnabled: false)
        let result = PanelTriggerAudit.audit(items: [disabled], context: context(routingItems: []))
        XCTAssertEqual(verdict(for: disabled, in: result)?.status, .unreachable)
        XCTAssertEqual(verdict(for: disabled, in: result)?.shortcutBlocker, .unresolvedByRouter)
        XCTAssertEqual(verdict(for: disabled, in: result)?.activationBlocker, .disabledItem)
    }

    /// The mirror case: the chord still reaches the app, so a refused click does not make
    /// the row unreachable. The hover text names the refusal instead.
    func testDisabledRowWithReachableChordIsStillExecutable() {
        let disabled = item(.combo([.command], KeyToken("p")), "Print", isEnabled: false)
        let result = PanelTriggerAudit.audit(
            items: [disabled],
            context: context(routingItems: [disabled])
        )
        XCTAssertEqual(verdict(for: disabled, in: result)?.status, .executable)
        XCTAssertNil(verdict(for: disabled, in: result)?.shortcutBlocker)
        XCTAssertEqual(verdict(for: disabled, in: result)?.activationBlocker, .disabledItem)
        XCTAssertTrue(result.unreachableRowIDs.isEmpty)
    }

    /// A restricted action (⌃⌘Q = Lock Screen) never runs from the panel, on either path.
    func testRestrictedActionWithBlockedChordIsUnreachable() {
        let lock = item(.combo([.control, .command], KeyToken("q")), "Lock Screen")
        let result = PanelTriggerAudit.audit(items: [lock], context: context(routingItems: []))
        XCTAssertEqual(verdict(for: lock, in: result)?.status, .unreachable)
        XCTAssertEqual(verdict(for: lock, in: result)?.activationBlocker, .refusedByPolicy)
    }

    /// A config-tool row is "shown only": a click copies its shortcut, it never runs.
    func testConfigRowWithBlockedChordIsUnreachable() {
        let config = item(.combo([.command], KeyToken("p")), "Tool Command", source: .configFile)
        let result = PanelTriggerAudit.audit(items: [config], context: context(routingItems: []))
        XCTAssertEqual(verdict(for: config, in: result)?.status, .unreachable)
        XCTAssertEqual(verdict(for: config, in: result)?.activationBlocker, .refusedByPolicy)
    }

    /// A system row has no menu element to press: an empty chord leaves it nothing to replay.
    func testSystemRowWithEmptyChordIsUnreachable() {
        let system = item(.empty, "Unnamed", source: .system)
        let result = PanelTriggerAudit.audit(items: [system], context: context())
        XCTAssertEqual(verdict(for: system, in: result)?.status, .unreachable)
        XCTAssertEqual(verdict(for: system, in: result)?.activationBlocker, .noExecutionTarget)
    }

    // MARK: - Shape of the answer

    func testEveryAuditedRowGetsItsOwnVerdictInOrder() {
        let first = item(.combo([.command], KeyToken("c")), "Copy")
        let second = item(.empty, "No Shortcut", axPath: "2,0,5")
        let result = PanelTriggerAudit.audit(
            items: [first, second],
            context: context(routingItems: [first])
        )
        XCTAssertEqual(result.verdicts.map(\.rowID), [first.id, second.id])
        XCTAssertEqual(result.verdicts.map(\.status), [.executable, .executable])
    }
}
