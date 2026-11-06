import XCTest
@testable import KanameCore

/// The reachability audit: a row the panel shows has to be a row a key can trigger. These
/// cases pin both halves of the ⌥⌘M / ⌥⌘F bug — the filter claiming the last key, and the
/// router being handed a catalog narrower than the list on screen — plus the repaired state.
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
        source: BindingSource = .menu
    ) -> BindingItem {
        BindingItem(chord: chord, title: title, group: ["Edit"], source: source)
    }

    private func context(
        filter: PanelFilter = PanelFilter(),
        held: ModifierSet = [],
        routingItems: [BindingItem] = []
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
            routingItems: routingItems
        )
    }

    private func narrowed(_ modifiers: ModifierSet...) -> PanelFilter {
        PanelFilter(tokens: modifiers.map { .modifier($0) })
    }

    /// A bare-letter chord really does belong to the filter: the audit must say so rather
    /// than quietly calling a swallowed key "triggerable".
    func testFilterClaimingTheLastKeyIsReported() {
        let bare = item(.combo([], KeyToken("f")), "Bare F")
        let result = PanelTriggerAudit.audit(
            items: [bare],
            context: context(filter: narrowed(.control), routingItems: [bare])
        )
        XCTAssertEqual(result.findings, [
            .init(rowID: bare.id, reason: .claimedByFilter)
        ])
    }

    /// The row came from `systemBindings` but the router only saw the app's menu catalog —
    /// exactly the ⌥⌘M case. The audit has to see "no match", not pass the panel's own list.
    func testSystemHotkeyOutOfTheRoutingCatalogIsReported() {
        let minimizeAll = item(
            .combo([.option, .command], KeyToken("m")),
            "Minimize All",
            source: .system
        )
        let result = PanelTriggerAudit.audit(
            items: [minimizeAll],
            context: context(routingItems: [])
        )
        XCTAssertEqual(result.findings, [
            .init(rowID: minimizeAll.id, reason: .unresolvedByRouter)
        ])
    }

    /// With the router fed the same set the panel draws from, the system hotkey completes:
    /// an ordinary physical chord passes through to the front app.
    func testSystemHotkeyInTheRoutingCatalogIsTriggerable() {
        let minimizeAll = item(
            .combo([.option, .command], KeyToken("m")),
            "Minimize All",
            source: .system
        )
        let result = PanelTriggerAudit.audit(
            items: [minimizeAll],
            context: context(routingItems: [minimizeAll])
        )
        XCTAssertTrue(result.findings.isEmpty)
    }

    /// Safari's Edit → Find ⌥⌘F while ⌥⌘ is narrowing the list: the last key carries the
    /// very modifiers in the filter, and must still be a chord rather than a search token.
    func testModifiedMenuShortcutStaysTriggerableWhileNarrowing() {
        let find = item(.combo([.option, .command], KeyToken("f")), "Search with Bing")
        let result = PanelTriggerAudit.audit(
            items: [find],
            context: context(
                filter: narrowed(.option, .command),
                held: [.option, .command],
                routingItems: [find]
            )
        )
        XCTAssertTrue(result.findings.isEmpty)
    }

    /// A panel-owned key (the bare slash that opens search) is a real reason a row cannot
    /// be triggered; it is reported as captured, not as a missing shortcut. A *modified*
    /// slash is an ordinary chord and must not be reported — `NavigationKey.isSlash`
    /// deliberately ignores ⌘/.
    func testPanelCapturedKeyIsReported() {
        let slash = item(.combo([], KeyToken("/")), "Slash")
        let result = PanelTriggerAudit.audit(
            items: [slash],
            context: context(routingItems: [slash])
        )
        XCTAssertEqual(result.findings.first?.reason, .capturedByPanelKey)

        let modified = item(.combo([.command], KeyToken("/")), "Command Slash")
        let ordinary = PanelTriggerAudit.audit(
            items: [modified],
            context: context(routingItems: [modified])
        )
        XCTAssertTrue(ordinary.findings.isEmpty)
    }

    /// The audit covers rows the current filter or page would hide: a problem is still a
    /// problem when the user has not scrolled to it yet.
    func testFindingsIncludeRowsOutsideTheCurrentView() {
        let hidden = item(.combo([.command], KeyToken("p")), "Print")
        let result = PanelTriggerAudit.audit(
            items: [hidden],
            context: context(filter: narrowed(.option), routingItems: [])
        )
        XCTAssertEqual(result.unreachableRowIDs, [hidden.id])
        XCTAssertEqual(result.reason(forRowID: hidden.id), .unresolvedByRouter)
    }
}
