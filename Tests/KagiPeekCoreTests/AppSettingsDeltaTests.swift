import XCTest
@testable import KagiPeekCore

/// Guards the settings diagnostic.
///
/// `changedFieldNames(from:)` is what a `changed: …` line in the log is built from, and that
/// line is what a "my setting does nothing" report quotes. It used to be a hand-written list of
/// comparisons in the engine and had fallen 14 fields behind, so the failure was silent: the
/// setting changed, nothing was logged, and the report had no evidence either way.
///
/// The two registries below are the tripwires. A new stored property fails
/// `testDescribedFieldsAreExactlyTheStoredProperties` until it is added to
/// `describedFields`, and fails `testEveryDescribedFieldIsObserved` until the mutation table
/// grows a case for it — which is also what proves the field is actually compared.
final class AppSettingsDeltaTests: XCTestCase {
    func testDescribedFieldsAreExactlyTheStoredProperties() {
        let stored = Mirror(reflecting: AppSettingsSnapshot()).children.compactMap(\.label)
        XCTAssertEqual(AppSettingsSnapshot.describedFields, Set(stored))
        XCTAssertEqual(
            AppSettingsSnapshot.describedFields.count,
            stored.count,
            "describedFields 里有重复登记或不存在字段"
        )
    }

    func testNothingChangedMeansNoDelta() {
        XCTAssertEqual(AppSettingsSnapshot().changedFieldNames(from: AppSettingsSnapshot()), [])
    }

    /// One mutation per field, each changing exactly one property.
    private static let mutations: [(name: String, apply: @Sendable (inout AppSettingsSnapshot) -> Void)] = [
        ("triggerMode", { $0.triggerMode = .hotkey }),
        ("modifierTriggerEnabled", { $0.modifierTriggerEnabled = false }),
        ("hotkeyTriggerEnabled", { $0.hotkeyTriggerEnabled = false }),
        ("triggerGesture", { $0.triggerGesture = .doubleTap }),
        ("triggerKey", { $0.triggerKey = .leftOption }),
        ("holdDelay", { $0.holdDelay = 0.7 }),
        ("panelHotkey", { $0.panelHotkey = nil }),
        ("searchHotkey", { $0.searchHotkey = nil }),
        ("switchHotkey", { $0.switchHotkey = nil }),
        ("panelPlacement", { $0.panelPlacement = .fillScreen }),
        ("fixedPanelWidth", { $0.fixedPanelWidth = 800 }),
        ("fixedPanelHeight", { $0.fixedPanelHeight = 700 }),
        ("showExecutedHUD", { $0.showExecutedHUD = false }),
        ("keyStyle", { $0.keyStyle = .words }),
        ("columnCount", { $0.columnCount = 3 }),
        ("maxItemsPerPage", { $0.maxItemsPerPage = 30 }),
        ("maxDescriptionLength", { $0.maxDescriptionLength = 40 }),
        ("showDisabledItems", { $0.showDisabledItems = false }),
        ("includeBuiltInCatalog", { $0.includeBuiltInCatalog = false }),
        ("showAppleMenu", { $0.showAppleMenu = true }),
        ("sortMode", { $0.sortMode = .alphabetical }),
        ("language", { $0.language = .chinese }),
        ("excludedBundleIDs", { $0.excludedBundleIDs = ["com.example.blocked"] }),
        ("launchAtLogin", { $0.launchAtLogin = true }),
        ("ignoredCommands", {
            $0.ignoredCommands = [IgnoredCommand(title: "Quit", appBundleID: "com.example.app")]
        }),
        ("panelTheme", { $0.panelTheme = .dark }),
        ("keyPosition", { $0.keyPosition = .left }),
        ("panelOrder", { $0.panelOrder = .byMenuGroup }),
        ("pinFavoritesToTop", { $0.pinFavoritesToTop = false }),
        ("favoritesCanBeFiltered", { $0.favoritesCanBeFiltered = true }),
        ("runRowKey", { $0.runRowKey = nil }),
        ("copyRowKey", {
            $0.copyRowKey = HotkeySpec(keyCode: KeyCode.returnKey, modifiers: [.command])
        }),
        ("pagingPairs", { $0.pagingPairs = [] }),
        ("scanConfigFiles", { $0.scanConfigFiles = false }),
        ("showConfigToolsInPanel", { $0.showConfigToolsInPanel = true }),
        ("diagnosticsEnabled", { $0.diagnosticsEnabled = false }),
        ("verboseDiagnostics", { $0.verboseDiagnostics = true }),
        ("showDockIcon", { $0.showDockIcon = true }),
    ]

    /// The log line lists fields in declaration order, not in whatever order a dictionary
    /// happened to iterate: the same two edits should read the same way twice.
    func testSeveralChangesAreListedInDeclarationOrder() {
        var changed = AppSettingsSnapshot()
        changed.columnCount = 3
        changed.pagingPairs = []
        changed.holdDelay = 0.7
        XCTAssertEqual(
            changed.changedFieldNames(from: AppSettingsSnapshot()),
            ["holdDelay", "columnCount", "pagingPairs"]
        )
    }

    func testEveryDescribedFieldIsObserved() {
        let names = Self.mutations.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "变异表里有重复项")
        XCTAssertEqual(
            Set(names),
            AppSettingsSnapshot.describedFields,
            "有字段没有对应的变异：新增字段要同时登记到 describedFields 和变异表"
        )
        for mutation in Self.mutations {
            var changed = AppSettingsSnapshot()
            mutation.apply(&changed)
            XCTAssertNotEqual(changed, AppSettingsSnapshot(), "\(mutation.name) 的变异没有改变任何值")
            XCTAssertEqual(
                changed.changedFieldNames(from: AppSettingsSnapshot()),
                [mutation.name],
                "\(mutation.name) 的改动没有被差分准确识别"
            )
        }
    }
}
