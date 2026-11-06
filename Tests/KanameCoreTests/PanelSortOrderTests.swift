import XCTest
@testable import KanameCore

final class PanelSortOrderTests: XCTestCase {
    // MARK: - Ordering

    func testByModifierIsTheExistingOrderUnchanged() {
        let items = [
            item("c", group: "Edit", axPath: "3,0,1", title: "Copy"),
            item("v", group: "Edit", axPath: "3,0,2", title: "Paste"),
            item("n", group: "File", axPath: "2,0,1", title: "New"),
            item("s", group: "File", axPath: "2,0,2", title: "Save"),
        ]
        XCTAssertEqual(
            PanelSortOrder.byModifier.sorted(items).map(\.id),
            PanelOrdering.sorted(items).map(\.id)
        )
    }

    func testByMenuGroupKeepsEveryTopLevelMenuContiguous() {
        let items = [
            item("c", group: "Edit", axPath: "3,0,1", title: "Copy"),
            item("s", group: "File", axPath: "2,0,2", title: "Save"),
            item("v", group: "Edit", axPath: "3,0,2", title: "Paste"),
            item("n", group: "File", axPath: "2,0,1", title: "New"),
        ]
        let sorted = PanelSortOrder.byMenuGroup.sorted(items)

        XCTAssertEqual(sorted.map(\.displayGroup), ["File", "File", "Edit", "Edit"])
        // Inside a menu the shortcut order is the old order, untouched.
        for group in ["File", "Edit"] {
            XCTAssertEqual(
                sorted.filter { $0.displayGroup == group }.map(\.id),
                PanelOrdering.sorted(items.filter { $0.displayGroup == group }).map(\.id)
            )
        }
    }

    func testMenuGroupOrderFollowsTheMenuBarIndex() {
        // Safari: 0 is the app menu, 2 File, 3 Edit. A menu's lowest index wins even when
        // the scan reports several indices for it.
        let items = [
            item("e", group: "Edit", axPath: "3,0,1", title: "Emoji"),
            item("f", group: "File", axPath: "2,0,1", title: "File item"),
            item("a", group: "App", axPath: "0,0,1", title: "About"),
        ]
        XCTAssertEqual(
            PanelSortOrder.byMenuGroup.sorted(items).map(\.displayGroup),
            ["App", "File", "Edit"]
        )
    }

    func testItemsWithoutAnAccessibilityPathFollowTheRankedMenus() {
        let items = [
            item("b", group: "Built-in", axPath: nil, title: "Built-in item"),
            item("f", group: "File", axPath: "2,0,1", title: "New"),
            item("x", group: "", axPath: nil, title: "No menu"),
        ]
        let sorted = PanelSortOrder.byMenuGroup.sorted(items)
        XCTAssertEqual(sorted.first?.displayGroup, "File")
        XCTAssertEqual(sorted.last?.displayGroup, "")
    }

    // MARK: - Shift hints follow the displayed order

    func testShiftLabelsFollowTheDisplayedPosition() {
        let items = [
            item("c", group: "Edit", axPath: "3,0,1", title: "Copy"),
            item("v", group: "Edit", axPath: "3,0,2", title: "Paste"),
            item("z", group: "Edit", axPath: "3,0,3", title: "Undo"),
            item("n", group: "File", axPath: "2,0,1", title: "New"),
            item("s", group: "File", axPath: "2,0,2", title: "Save"),
            item("f", group: "File", axPath: "2,0,3", title: "Find"),
        ]
        let byModifier = PanelSortOrder.byModifier.sorted(items)
        let byGroup = PanelSortOrder.byMenuGroup.sorted(items)
        let modifierLabels = ShiftHintLayer.labels(for: byModifier.map(\.id))
        let groupLabels = ShiftHintLayer.labels(for: byGroup.map(\.id))

        // `0` is the first row on screen, not the first menu item the scan happened to see.
        XCTAssertEqual(owner(of: "0", in: modifierLabels), byModifier.first?.id)
        XCTAssertEqual(owner(of: "5", in: modifierLabels), byModifier[5].id)
        XCTAssertEqual(owner(of: "0", in: groupLabels), byGroup.first?.id)
        XCTAssertEqual(owner(of: "5", in: groupLabels), byGroup[5].id)

        // Same glyph table, different targets: switching the order moves the labels.
        XCTAssertEqual(Set(modifierLabels.values), Set(groupLabels.values))
        XCTAssertNotEqual(modifierLabels, groupLabels)
    }

    // MARK: - Persistence

    func testDefaultOrderIsByModifier() {
        XCTAssertEqual(AppSettingsSnapshot().panelOrder, .byModifier)
    }

    func testSchemaVersionFiveWithoutPanelOrderMigratesToTheDefault() throws {
        let json = #"{"schemaVersion":5,"settings":{"maxItemsPerPage":60}}"#
        let payload = try JSONDecoder().decode(SettingsPayload.self, from: Data(json.utf8))
        XCTAssertTrue(SettingsMigrator.isOutdated(payload))
        XCTAssertEqual(SettingsMigrator.migrate(payload).panelOrder, .byModifier)
    }

    func testCurrentSchemaWritesVersionElevenAndTheOrder() throws {
        var settings = AppSettingsSnapshot()
        settings.panelOrder = .byMenuGroup
        let payload = SettingsPayload(schemaVersion: AppSettingsSnapshot.currentSchemaVersion, settings: settings)
        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["schemaVersion"] as? Int, 11)
        let storedSettings = try XCTUnwrap(object["settings"] as? [String: Any])
        XCTAssertEqual(storedSettings["panelOrder"] as? String, "byMenuGroup")
    }

    func testOrderRoundTripsThroughThePayload() throws {
        var settings = AppSettingsSnapshot()
        settings.panelOrder = .byMenuGroup
        let data = try JSONEncoder().encode(SettingsPayload(
            schemaVersion: AppSettingsSnapshot.currentSchemaVersion,
            settings: settings
        ))
        let payload = try JSONDecoder().decode(SettingsPayload.self, from: data)
        XCTAssertEqual(SettingsMigrator.migrate(payload).panelOrder, .byMenuGroup)
    }

    func testCorruptPayloadDoesNotDecode() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(SettingsPayload.self, from: Data("not json".utf8))
        )
    }

    // MARK: - Helpers

    private func item(
        _ key: String,
        group: String,
        axPath: String?,
        title: String
    ) -> BindingItem {
        BindingItem(
            chord: KeyChord([.combo([.command], KeyToken(key))]),
            title: title,
            group: group.isEmpty ? [] : [group],
            source: .menu,
            appBundleID: "com.apple.Safari",
            axPath: axPath
        )
    }

    private func owner(of label: String, in labels: [String: String]) -> String? {
        labels.first { $0.value == label }?.key
    }
}
