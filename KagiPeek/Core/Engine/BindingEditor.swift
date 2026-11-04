import AppKit

/// Owns "which binding is being recorded" and what one key event means while recording.
///
/// Recording is a settings-window interaction, but its rules are not: `RecordingPolicy`
/// decides, this class applies the decision to `EngineState` and `SettingsStore`, and the
/// engine only supplies the one side effect it owns — deciding whether the event tap should
/// swallow events (`applyHotkeySwallowing`).
@MainActor
final class BindingEditor {
    private let state: EngineState
    private let settingsStore: SettingsStore
    /// Called whenever the recording target or the bound spec changes, so the engine can
    /// re-arm the event tap.
    private let onChange: () -> Void

    init(state: EngineState, settingsStore: SettingsStore, onChange: @escaping () -> Void) {
        self.state = state
        self.settingsStore = settingsStore
        self.onChange = onChange
    }

    func begin(_ target: HotkeyTarget) {
        state.recordingTarget = target
        onChange()
    }

    func cancel() {
        guard state.recordingTarget != nil else { return }
        state.recordingTarget = nil
        onChange()
    }

    /// Applies one event to the active recording. Returns `true` when the event was
    /// swallowed, which is always the case while a target is set.
    func handle(_ event: KeyEvent, target: HotkeyTarget) -> Bool {
        switch RecordingPolicy.decision(for: event, target: target) {
        case .consume:
            return true
        case .cancel:
            state.recordingTarget = nil
            onChange()
            return true
        case let .assign(spec):
            switch target {
            case .panel:
                settingsStore.settings.panelHotkey = spec
            case .search:
                settingsStore.settings.searchHotkey = spec
            case .switcher:
                settingsStore.settings.switchHotkey = spec
            case .runRow:
                settingsStore.settings.runRowKey = spec
            case .copyRow:
                settingsStore.settings.copyRowKey = spec
            }
            state.recordingTarget = nil
            onChange()
            return true
        }
    }
}
