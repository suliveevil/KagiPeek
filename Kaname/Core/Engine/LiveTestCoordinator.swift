import AppKit

/// The "test this shortcut" flow: listening, polling, and the verdict against every known
/// owner of the chord.
///
/// `ShortcutTester` owns the timing and mutates its own state, so published state has to be
/// pulled across rather than pushed from inside it — that polling is the only reason this
/// class has a task.
@MainActor
final class LiveTestCoordinator {
    private let state: EngineState
    private let externalBindings: () -> [BindingItem]
    private let ownerName: (String) -> String?
    private let dismissPanel: () -> Void
    private let onListeningChanged: (Bool) -> Void
    private let appToRestore: () -> NSRunningApplication?

    private lazy var tester = ShortcutTester(
        appToRestore: appToRestore,
        onListeningChanged: onListeningChanged
    )

    init(
        state: EngineState,
        externalBindings: @escaping () -> [BindingItem],
        ownerName: @escaping (String) -> String?,
        dismissPanel: @escaping () -> Void,
        onListeningChanged: @escaping (Bool) -> Void,
        appToRestore: @escaping () -> NSRunningApplication?
    ) {
        self.state = state
        self.externalBindings = externalBindings
        self.ownerName = ownerName
        self.dismissPanel = dismissPanel
        self.onListeningChanged = onListeningChanged
        self.appToRestore = appToRestore
    }

    func start(for chord: KeyChord) {
        dismissPanel()
        tester.start(for: chord)
        state.liveTestState = tester.state
    }

    func cancel() {
        tester.cancel()
        state.liveTestState = tester.state
    }

    /// The verdict of a finished test for `chord`, or nil when no test of it has run.
    func verdict(for chord: KeyChord) -> LiveTestVerdict? {
        tester.verdict(
            for: chord,
            items: state.catalog.items + externalBindings()
        ) { [weak self] bundleID in self?.ownerName(bundleID) }
    }

    /// The combo the tester is currently busy with, so a row knows whether the countdown on
    /// screen belongs to it or to a different chord.
    var chord: KeyChord? { tester.testedChord }

    /// Polls the tester while it is listening. The tester owns the timing and mutates its own
    /// state, so published state has to be pulled across rather than pushed from inside it.
    func startCountdown() {
        state.liveTestPollingTask?.cancel()
        state.liveTestPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                let current = self.tester.state
                if self.state.liveTestState != current {
                    self.state.liveTestState = current
                }
            }
        }
    }
}
