import XCTest
@testable import KagiPeekCore

/// The config parsers, fed fixtures rather than real files.
///
/// Each parser is split from its file access for exactly this reason: a user's `~/.config`
/// is not a test fixture, and a scanner that could only be exercised against a real Karabiner
/// install would only ever be tested on the machines that happen to have one.
final class ConfigScannerTests: XCTestCase {

    // MARK: - Karabiner

    func testKarabinerReadsMandatoryModifiers() {
        let json = """
        {
          "profiles": [
            {
              "selected": true,
              "complex_modifications": {
                "rules": [
                  {
                    "description": "Launch Terminal",
                    "manipulators": [
                      {
                        "from": {
                          "key_code": "t",
                          "modifiers": { "mandatory": ["command", "shift"], "optional": ["any"] }
                        },
                        "to": [{ "key_code": "x" }],
                        "type": "basic"
                      }
                    ]
                  }
                ]
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let bindings = KarabinerScanner.bindings(fromJSON: json)
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(bindings[0].chord, KeyChord.combo([.command, .shift], KeyToken("t")))
        XCTAssertEqual(bindings[0].title, "Launch Terminal")
    }

    func testKarabinerSkipsBareKeyRemaps() {
        // A rule with no mandatory modifier fires on every press of that key. Reporting it
        // would claim a conflict with every menu item bound to the same letter.
        let json = """
        { "profiles": [{ "complex_modifications": { "rules": [
            { "description": "caps to escape", "manipulators": [
                { "from": { "key_code": "caps_lock" }, "type": "basic" }] }] } }] }
        """.data(using: .utf8)!
        XCTAssertTrue(KarabinerScanner.bindings(fromJSON: json).isEmpty)
    }

    func testKarabinerUsesTheSelectedProfile() {
        let json = """
        { "profiles": [
            { "complex_modifications": { "rules": [
                { "description": "inactive", "manipulators": [
                    { "from": { "key_code": "a", "modifiers": { "mandatory": ["command"] } } }] }] } },
            { "selected": true, "complex_modifications": { "rules": [
                { "description": "active", "manipulators": [
                    { "from": { "key_code": "b", "modifiers": { "mandatory": ["command"] } } }] }] } }
        ] }
        """.data(using: .utf8)!
        XCTAssertEqual(KarabinerScanner.bindings(fromJSON: json).first?.title, "active")
    }

    func testKarabinerNamedKeys() {
        XCTAssertEqual(KarabinerScanner.token(forKarabinerKey: "return_or_enter"), KeyToken("return"))
        XCTAssertEqual(KarabinerScanner.token(forKarabinerKey: "left_arrow"), KeyToken("left"))
        XCTAssertEqual(KarabinerScanner.token(forKarabinerKey: "f5"), KeyToken("f5"))
    }

    // MARK: - skhd

    func testSkhdParsesModifiersAndCommand() {
        let bindings = SkhdScanner.bindings(from: "cmd + shift - 4 : ~/bin/shot.sh\n")
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(bindings[0].chord, KeyChord.combo([.command, .shift], KeyToken("4")))
        XCTAssertEqual(bindings[0].title, "~/bin/shot.sh")
    }

    func testSkhdExpandsHyperAndMeh() {
        XCTAssertEqual(SkhdScanner.modifiers(from: "hyper"), [.command, .control, .option, .shift])
        XCTAssertEqual(SkhdScanner.modifiers(from: "meh"), [.control, .option, .shift])
    }

    func testSkhdSkipsCommentsAndModeBlocks() {
        let source = """
        # cmd - a : commented out
        :: focus @ : open -a Finder
        focus < cmd - b : in a mode
        """
        XCTAssertTrue(SkhdScanner.bindings(from: source).isEmpty)
    }

    func testSkhdRequiresAModifier() {
        // A bare key is a keystroke, not a shortcut.
        XCTAssertTrue(SkhdScanner.bindings(from: "4 : echo hi").isEmpty)
    }

    // MARK: - Keyboard Maestro

    func testKeyboardMaestroReadsHotKeyTriggers() throws {
        let plist: [String: Any] = [
            "MacroGroups": [[
                "Name": "Everyday",
                "IsActive": true,
                "Macros": [[
                    "Name": "Open Notes",
                    "IsActive": true,
                    "Triggers": [[
                        "MacroTriggerType": "HotKey",
                        "KeyCode": 8,           // c
                        "Modifiers": 256 + 512  // cmd + shift
                    ]]
                ]]
            ]]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let bindings = KeyboardMaestroScanner.bindings(fromPlist: try PropertyListSerialization.propertyList(from: data, format: nil))
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(bindings[0].chord, KeyChord.combo([.command, .shift], KeyToken("c")))
        XCTAssertEqual(bindings[0].title, "Everyday › Open Notes")
    }

    func testKeyboardMaestroSkipsInactiveMacrosAndGroups() {
        let plist: [[String: Any]] = [[
            "Name": "Off",
            "IsActive": false,
            "Macros": [[
                "Name": "Never runs",
                "Triggers": [["MacroTriggerType": "HotKey", "KeyCode": 8, "Modifiers": 256]]
            ]]
        ]]
        XCTAssertTrue(KeyboardMaestroScanner.bindings(fromPlist: plist).isEmpty)
    }

    func testKeyboardMaestroIgnoresOtherTriggerTypes() {
        let plist: [[String: Any]] = [[
            "Macros": [[
                "Name": "Typed string",
                "Triggers": [["MacroTriggerType": "TypedString", "KeyCode": 8, "Modifiers": 256]]
            ]]
        ]]
        XCTAssertTrue(KeyboardMaestroScanner.bindings(fromPlist: plist).isEmpty)
    }

    // MARK: - Hammerspoon

    func testHammerspoonReadsATableOfModifiers() {
        let source = """
        hs.hotkey.bind({"cmd", "shift"}, "4", "Screenshot", function() end)
        """
        let bindings = HammerspoonScanner.bindings(from: source)
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(bindings[0].chord, KeyChord.combo([.command, .shift], KeyToken("4")))
        XCTAssertEqual(bindings[0].title, "Screenshot")
    }

    func testHammerspoonSkipsCommentedOutBinds() {
        let source = """
        -- hs.hotkey.bind({"cmd"}, "1", function() end)
        hs.hotkey.bind({"cmd"}, "2", function() end)
        """
        let bindings = HammerspoonScanner.bindings(from: source)
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(bindings[0].chord, KeyChord.combo([.command], KeyToken("2")))
    }

    func testHammerspoonRefusesToGuessAnUnresolvableModifierTable() {
        // `hyper` is a variable here. A half-resolved set would understate the combo, so
        // the whole bind is dropped instead.
        let source = "hs.hotkey.bind({hyper, \"shift\"}, \"4\", function() end)"
        XCTAssertTrue(HammerspoonScanner.bindings(from: source).isEmpty)
    }

    func testHammerspoonAcceptsAPackedModifierString() {
        let source = "hs.hotkey.bind(\"cmd-alt\", \"t\", function() end)"
        let bindings = HammerspoonScanner.bindings(from: source)
        XCTAssertEqual(bindings[0].chord, KeyChord.combo([.command, .option], KeyToken("t")))
    }

    func testHammerspoonNamedKeys() {
        XCTAssertEqual(HammerspoonScanner.token(forHammerspoonKey: "escape"), KeyToken("esc"))
        XCTAssertEqual(HammerspoonScanner.token(forHammerspoonKey: "padenter"), KeyToken("enter"))
    }

    // MARK: - Alfred

    func testAlfredRequiresAnAssignedHotstring() {
        let unassigned: [String: Any] = [
            "objects": [[
                "type": "alfred.workflow.trigger.hotkey",
                "config": ["hotkey": 0, "hotmod": 0, "hotstring": ""]
            ]]
        ]
        XCTAssertTrue(AlfredScanner.bindings(fromWorkflow: unassigned).isEmpty)

        let assigned: [String: Any] = [
            "name": "Clipboard",
            "objects": [[
                "type": "alfred.workflow.trigger.hotkey",
                "config": ["hotkey": 8, "hotmod": 1048576, "hotstring": "⌘C"]
            ]]
        ]
        let bindings = AlfredScanner.bindings(fromWorkflow: assigned)
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(bindings[0].chord, KeyChord.combo([.command], KeyToken("c")))
        XCTAssertEqual(bindings[0].title, "Clipboard")
    }

    func testAlfredSkipsDisabledWorkflows() {
        let workflow: [String: Any] = [
            "disabled": true,
            "objects": [[
                "type": "alfred.workflow.trigger.hotkey",
                "config": ["hotkey": 8, "hotmod": 1048576, "hotstring": "⌘C"]
            ]]
        ]
        XCTAssertTrue(AlfredScanner.bindings(fromWorkflow: workflow).isEmpty)
    }

    // MARK: - BetterTouchTool

    func testBetterTouchToolParsesKeyboardShortcutRows() throws {
        let trigger: [String: Any] = [
            "BTTTriggerClass": "BTTTriggerTypeKeyboardShortcut",
            "BTTShortcutKeyCode": 8,
            "BTTShortcutModifierKeys": 1048576 + 131072, // cmd + shift
            "BTTPredefinedActionName": "Screenshot"
        ]
        let container: [String: Any] = ["BTTAppBundleIdentifier": "BT.G"]
        let rows = [
            BetterTouchToolScanner.Row(
                pk: 1, parent: nil,
                json: try JSONSerialization.data(withJSONObject: trigger)
            ),
            BetterTouchToolScanner.Row(
                pk: 2, parent: nil,
                json: try JSONSerialization.data(withJSONObject: container)
            )
        ]
        let bindings = BetterTouchToolScanner.bindings(from: rows)
        XCTAssertEqual(bindings.count, 1)
        XCTAssertEqual(bindings[0].chord, KeyChord.combo([.command, .shift], KeyToken("c")))
        XCTAssertEqual(bindings[0].title, "Screenshot")
    }

    func testBetterTouchToolSkipsAppScopedAndDisabledTriggers() throws {
        let scoped: [String: Any] = [
            "BTTTriggerClass": "BTTTriggerTypeKeyboardShortcut",
            "BTTShortcutKeyCode": 8,
            "BTTShortcutModifierKeys": 1048576
        ]
        let disabled: [String: Any] = [
            "BTTTriggerClass": "BTTTriggerTypeKeyboardShortcut",
            "BTTShortcutKeyCode": 9,
            "BTTShortcutModifierKeys": 1048576,
            "BTTEnabled2": 0
        ]
        let container: [String: Any] = ["BTTAppBundleIdentifier": "com.apple.Safari"]
        let rows = [
            BetterTouchToolScanner.Row(pk: 1, parent: 3, json: try JSONSerialization.data(withJSONObject: scoped)),
            BetterTouchToolScanner.Row(pk: 2, parent: 3, json: try JSONSerialization.data(withJSONObject: disabled)),
            BetterTouchToolScanner.Row(pk: 3, parent: nil, json: try JSONSerialization.data(withJSONObject: container))
        ]
        XCTAssertTrue(BetterTouchToolScanner.bindings(from: rows).isEmpty)
    }

    func testBetterTouchToolLayoutIndependentCharacters() {
        XCTAssertEqual(BetterTouchToolScanner.token(forLayoutIndependentChar: "SPACE"), KeyToken("space"))
        XCTAssertEqual(BetterTouchToolScanner.token(forLayoutIndependentChar: "a"), KeyToken("a"))
    }

    // MARK: - Orchestration

    func testScanReportsEmptyWhenNothingIsInstalled() {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kagipeek-no-tools-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let result = ConfigFileScanner.scan(homeDirectory: home)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.counts.count, ConfigTool.allCases.count)
    }

    func testConfigBindingsCarryTheirTool() {
        let item = ConfigFileScanner.item(
            ConfigBinding(chord: .combo([.command], KeyToken("k")), title: "Rule"),
            tool: .karabiner
        )
        XCTAssertEqual(item.configTool, .karabiner)
        XCTAssertEqual(item.source, .configFile)
        XCTAssertEqual(item.group, ["Karabiner-Elements"])
        // The owner has to survive into the id: two tools binding the same chord to the
        // same title must not collapse into one row.
        XCTAssertTrue(item.id.hasPrefix("karabiner|"))
    }

    func testEveryToolKnowsWhichLayerItHooks() {
        XCTAssertEqual(ConfigTool.karabiner.layer, .driver)
        XCTAssertEqual(ConfigTool.skhd.layer, .eventTap)
        XCTAssertEqual(ConfigTool.betterTouchTool.layer, .eventTap)
        XCTAssertEqual(ConfigTool.keyboardMaestro.layer, .eventTap)
        XCTAssertEqual(ConfigTool.hammerspoon.layer, .globalHotKey)
        XCTAssertEqual(ConfigTool.alfred.layer, .globalHotKey)
    }
}
