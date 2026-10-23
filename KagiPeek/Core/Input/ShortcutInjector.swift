import CoreGraphics
import Foundation
import os

/// Replays a shortcut into whichever app is in front.
///
/// The search palette takes keyboard focus while it is open, so after closing it we
/// re-activate the app that was in front and post the chord's key events to it.
enum ShortcutInjector {
    static func post(_ chord: KeyChord, delay: TimeInterval = 0.15) {
        let steps = chord.steps.filter { $0.key != nil }
        guard !steps.isEmpty else {
            // Nothing was posted, so nothing happened in the app — indistinguishable from a
            // command that ran and did nothing.
            Diag.error(.inject, "empty chord, nothing posted")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            post(steps: steps, index: 0)
        }
    }

    private static func post(steps: [KeyStep], index: Int) {
        guard index < steps.count else { return }
        let step = steps[index]
        guard let key = step.key, let keyCode = KeyMapper.keyCode(for: key) else {
            Diag.error(.inject, "step skipped: no virtual key for \(step.key.map { "\($0)" } ?? "nil")")
            post(steps: steps, index: index + 1)
            return
        }
        postKey(keyCode: keyCode, flags: cgFlags(step.modifiers))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            post(steps: steps, index: index + 1)
        }
    }

    private static func postKey(keyCode: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            // A silent failure here is indistinguishable from "the app ignored the shortcut".
            AppLog.input.error("could not create key events for virtual key \(keyCode)")
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func cgFlags(_ modifiers: ModifierSet) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        return flags
    }
}
