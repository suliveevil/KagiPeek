import XCTest
@testable import KanameCore

/// The panel's message to Karabiner-Elements.
///
/// The transport (`KarabinerBridge`) spawns a process and is not worth unit-testing; the two
/// things that can be wrong and would be invisible at runtime are the payload a rule has to
/// match and the decision about when the variable must be 0.
final class KarabinerPanelSignalTests: XCTestCase {
    func testPayloadCarriesTheVariableAndOneOrZero() throws {
        let visible = KarabinerPanelSignal.payload(panelIsVisible: true)
        let hidden = KarabinerPanelSignal.payload(panelIsVisible: false)
        XCTAssertNotEqual(visible, hidden)
        for (payload, expected) in [(visible, 1), (hidden, 0)] {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Int]
            )
            XCTAssertEqual(object, [KarabinerPanelSignal.variableName: expected])
        }
    }

    /// The name is written into the user's Karabiner rule by hand, so it has to stay a plain
    /// word — a dotted or prefixed name is one more thing a copied rule gets wrong.
    func testVariableNameIsASinglePlainWord() {
        XCTAssertEqual(KarabinerPanelSignal.variableName, "kaname_panel")
    }

    /// Off has to mean 0 even while the panel is up: a leftover 1 would keep suppressing the
    /// user's rule after they turned the switch off.
    func testTheSwitchOffAlwaysMeansZero() {
        XCTAssertTrue(KarabinerPanelSignal.desiredState(panelIsVisible: true, isEnabled: true))
        XCTAssertFalse(KarabinerPanelSignal.desiredState(panelIsVisible: true, isEnabled: false))
        XCTAssertFalse(KarabinerPanelSignal.desiredState(panelIsVisible: false, isEnabled: true))
        XCTAssertFalse(KarabinerPanelSignal.desiredState(panelIsVisible: false, isEnabled: false))
    }

    /// A v10 file has no key. The default is on, because without it a user whose trigger key
    /// is bound in Karabiner has no way to make the panel narrowable.
    func testOlderSettingsDecodeToTheSwitchBeingOn() throws {
        let json = Data(#"{"schemaVersion":10,"settings":{"holdDelay":0.5}}"#.utf8)
        let payload = try JSONDecoder().decode(SettingsPayload.self, from: json)
        XCTAssertTrue(payload.settings.karabinerPanelSignalEnabled)
        XCTAssertEqual(SettingsMigrator.migrate(payload).karabinerPanelSignalEnabled, true)
    }

    /// The switch has to survive a save, or it would silently return to on at every launch.
    func testTheSwitchRoundTrips() throws {
        var settings = AppSettingsSnapshot()
        settings.karabinerPanelSignalEnabled = false
        let payload = SettingsPayload(
            schemaVersion: AppSettingsSnapshot.currentSchemaVersion,
            settings: settings
        )
        let encoded = try JSONEncoder().encode(payload)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let stored = object?["settings"] as? [String: Any]
        XCTAssertEqual(stored?["karabinerPanelSignalEnabled"] as? Bool, false)
        let decoded = try JSONDecoder().decode(SettingsPayload.self, from: encoded)
        XCTAssertFalse(decoded.settings.karabinerPanelSignalEnabled)
    }
}
