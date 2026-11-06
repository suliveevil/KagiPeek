import XCTest
@testable import KanameCore

/// Pins the recording table that used to be a double switch inside the engine. Every case
/// below is one branch of `ShortcutEngine.handleRecording`, so moving the rules into
/// `RecordingPolicy` cannot change what a key does while a binding is being recorded.
final class RecordingPolicyTests: XCTestCase {
    private func event(
        _ kind: KeyEventKind,
        keyCode: UInt16,
        key: String? = nil,
        modifiers: ModifierSet = [],
        isRepeat: Bool = false
    ) -> KeyEvent {
        KeyEvent(
            kind: kind,
            modifiers: modifiers,
            key: key.map { KeyToken($0) },
            keyCode: keyCode,
            isRepeat: isRepeat,
            happenedAt: Date()
        )
    }

    func testModifierAndKeyUpEventsAreConsumedWithoutWriting() {
        XCTAssertEqual(
            RecordingPolicy.decision(for: event(.flagsChanged, keyCode: 55), target: .panel),
            .consume
        )
        XCTAssertEqual(
            RecordingPolicy.decision(for: event(.keyUp, keyCode: 0, key: "c"), target: .panel),
            .consume
        )
    }

    func testInterruptionCancelsRecording() {
        XCTAssertEqual(
            RecordingPolicy.decision(for: event(.interruption, keyCode: 0), target: .search),
            .cancel
        )
    }

    func testRepeatIsConsumed() {
        XCTAssertEqual(
            RecordingPolicy.decision(
                for: event(.keyDown, keyCode: 0, key: "a", modifiers: [.command], isRepeat: true),
                target: .search
            ),
            .consume
        )
    }

    func testBareEscapeCancelsForEveryTarget() {
        for target in [HotkeyTarget.panel, .search, .switcher, .runRow, .copyRow] {
            XCTAssertEqual(
                RecordingPolicy.decision(for: event(.keyDown, keyCode: KeyCode.escape), target: target),
                .cancel,
                "Esc should cancel recording for \(target)"
            )
        }
    }

    func testGlobalHotkeyRequiresAModifier() {
        XCTAssertEqual(
            RecordingPolicy.decision(for: event(.keyDown, keyCode: 0, key: "a"), target: .panel),
            .consume
        )
        for modifier in [ModifierSet.command, .option, .control] {
            XCTAssertEqual(
                RecordingPolicy.decision(
                    for: event(.keyDown, keyCode: 0, key: "a", modifiers: modifier),
                    target: .panel
                ),
                .assign(HotkeySpec(keyCode: 0, modifiers: modifier))
            )
        }
    }

    func testGlobalHotkeyRejectsShiftOnly() {
        XCTAssertEqual(
            RecordingPolicy.decision(
                for: event(.keyDown, keyCode: 0, key: "a", modifiers: [.shift]),
                target: .search
            ),
            .consume
        )
    }

    func testRowKeyAcceptsBareSpaceAndReturn() {
        XCTAssertEqual(
            RecordingPolicy.decision(
                for: event(.keyDown, keyCode: KeyCode.space, key: "space"),
                target: .runRow
            ),
            .assign(HotkeySpec(keyCode: KeyCode.space, modifiers: []))
        )
        XCTAssertEqual(
            RecordingPolicy.decision(
                for: event(.keyDown, keyCode: KeyCode.returnKey, key: "return"),
                target: .copyRow
            ),
            .assign(HotkeySpec(keyCode: KeyCode.returnKey, modifiers: []))
        )
    }

    func testRowKeyRejectsBareCharacter() {
        XCTAssertEqual(
            RecordingPolicy.decision(
                for: event(.keyDown, keyCode: 0, key: "a"),
                target: .runRow
            ),
            .consume
        )
    }

    func testRowKeyAcceptsCharacterWithModifiers() {
        XCTAssertEqual(
            RecordingPolicy.decision(
                for: event(.keyDown, keyCode: 0, key: "a", modifiers: [.command]),
                target: .copyRow
            ),
            .assign(HotkeySpec(keyCode: 0, modifiers: [.command]))
        )
    }

    func testRowKeyReservedKeysAreConsumedEvenWithModifiers() {
        XCTAssertEqual(
            RecordingPolicy.decision(
                for: event(.keyDown, keyCode: KeyCode.left, modifiers: [.command]),
                target: .runRow
            ),
            .consume
        )
        for arrow in KeyCode.arrows {
            XCTAssertEqual(
                RecordingPolicy.decision(for: event(.keyDown, keyCode: arrow), target: .copyRow),
                .consume
            )
        }
    }
}
