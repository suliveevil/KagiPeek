import AppKit
import Combine
import Foundation

/// How a permission is drawn: a title, an icon, and the concrete things it enables.
///
/// A value of its own because these four travel together and never vary independently — the
/// permission card and the drag guide both read all four, and an eleven-argument initialiser
/// was the reason nobody could tell which half of them was presentation and which was policy.
struct PermissionPresentation {
    let titleKey: L10nKey
    let iconName: String
    let iconColorName: String
    let detailKeys: [L10nKey]
}

/// What the app does about a permission: whether it is required, where the switch lives, and
/// whether asking for it through the system API adds the app to the list **switched off**.
///
/// Accessibility is that last case: `AXIsProcessTrustedWithOptions(prompt:)` registers the
/// app before the user has done anything, and a registered-but-off entry is exactly the state
/// the drag instruction cannot fix — dragging it in again is how you end up with the "already
/// listed but the switch won't stick" support question. LobeHub's desktop guide dropped the
/// pre-registration for the same reason, so the guided flow opens System Settings and lets the
/// drop both add *and* enable the entry.
struct PermissionPolicy {
    let isRequired: Bool
    let settingsURL: URL?
    let promptPreRegisters: Bool

    init(isRequired: Bool, settingsURL: URL?, promptPreRegisters: Bool = false) {
        self.isRequired = isRequired
        self.settingsURL = settingsURL
        self.promptPreRegisters = promptPreRegisters
    }
}

/// One system permission KagiPeek may need.
///
/// Modelled after the permission cards in Thaw (thaw-app/Thaw): a title, an icon, the
/// concrete things the permission enables, whether it is required, the exact settings pane,
/// and a poll that stops as soon as the grant is detected.
@MainActor
final class AppPermission: ObservableObject, Identifiable {
    enum Identifier: String {
        case accessibility
        case inputMonitoring
    }

    let id: Identifier
    let presentation: PermissionPresentation
    let policy: PermissionPolicy

    @Published private(set) var isGranted: Bool

    /// What the permission row should say about the drag guide, so the row can report
    /// "waiting" while the panel is up and "continue" once it closed without a grant.
    @Published private(set) var guideStatus: GuideStatus = .idle

    enum GuideStatus: Equatable {
        /// No guide has been opened for this permission in this session.
        case idle
        /// The guide is on screen; the row is waiting for the user, not for a click.
        case waiting
        /// The guide was closed before the grant landed; the row offers to continue.
        case interrupted
    }

    var onChange: ((Bool) -> Void)?


    /// Fired after the matching System Settings pane has been opened — by both
    /// `performRequest()` and `openSettingsPane()` — so the UI can anchor a drag guide
    /// to the Settings window.
    var onSettingsPaneOpened: (() -> Void)?

    private let check: () -> Bool
    private let requestPrompt: () -> Bool

    init(
        id: Identifier,
        presentation: PermissionPresentation,
        policy: PermissionPolicy,
        check: @escaping () -> Bool,
        requestPrompt: @escaping () -> Bool
    ) {
        self.id = id
        self.presentation = presentation
        self.policy = policy
        self.check = check
        self.requestPrompt = requestPrompt
        self.isGranted = check()
    }

    /// Re-reads the system and reports a change exactly once.
    ///
    /// - Parameter noticedBy: what triggered the check. Carried into the log because a grant
    ///   has several possible discoverers — the poller, the distributed notification, the
    ///   activation and wake refreshes — and during the 2026-11-02 investigation the log could
    ///   not say which had spotted one, so a poller was credited with an observation a drag had
    ///   actually produced.
    func refresh(noticedBy reason: String) {
        let granted = check()
        guard granted != isGranted else { return }
        isGranted = granted
        if granted { guideStatus = .idle }
        Diag.info(.perm, "\(id.rawValue) \(granted ? "granted" : "revoked") (\(reason))")
        onChange?(granted)
    }

    func setGuideStatus(_ status: GuideStatus) {
        guard guideStatus != status else { return }
        guideStatus = status
    }

    /// Fire the system prompt *and* open the matching System Settings pane, so the flow can
    /// be recovered if the user closes System Settings without granting.
    ///
    /// A permission whose prompt pre-registers the app skips the prompt: opening the pane
    /// and letting the guide's drag do the work is the only path that leaves the entry
    /// enabled, and it is the same fix LobeHub shipped for Accessibility.
    func performRequest() {
        if !policy.promptPreRegisters {
            _ = requestPrompt()
        }
        openSettingsPane()
    }

    /// Opens the pane and raises Settings.
    ///
    /// The raise is explicit because a deep link does not bring an already-running Settings
    /// forward — without it the guide floats over whatever the user was looking at.
    func openSettingsPane() {
        if let url = policy.settingsURL {
            NSWorkspace.shared.open(url)
        }
        SettingsWindowLocator.activateSettings()
        onSettingsPaneOpened?()
    }

}

/// Aggregates the permissions and exposes the state the UI needs.
@MainActor
final class AppPermissions: ObservableObject {
    enum State: Equatable {
        case missing
        case requiredGranted
        case allGranted
    }

    let accessibility: AppPermission
    let inputMonitoring: AppPermission

    @Published private(set) var state: State = .missing

    /// Called whenever any permission changes (including while the window is open).
    var onChange: (() -> Void)?

    private var systemChangeObserver: (any NSObjectProtocol)?
    /// The one poller. There used to be two — a per-permission 3s timer that ran only while a
    /// grant was missing, and a global 5s one that watched for revocation — and they could both
    /// fire for the same change, which is why the log could not say which had noticed it.
    private var pollTimer: Timer?

    var all: [AppPermission] { [accessibility, inputMonitoring] }
    var required: [AppPermission] { all.filter(\.policy.isRequired) }

    init(previewDenied: Bool = false) {
        accessibility = AppPermission(
            id: .accessibility,
            presentation: PermissionPresentation(
                titleKey: .permissionAccessibility,
                iconName: "accessibility",
                iconColorName: "blue",
                detailKeys: [
                    .permissionAccessibilityDetail1,
                    .permissionAccessibilityDetail2,
                    .permissionAccessibilityDetail3
                ]
            ),
            policy: PermissionPolicy(
                isRequired: true,
                settingsURL: PermissionCenter.accessibilitySettingsURL,
                promptPreRegisters: true
            ),
            check: { previewDenied ? false : AXIsProcessTrusted() },
            requestPrompt: {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                return AXIsProcessTrustedWithOptions(options)
            }
        )

        inputMonitoring = AppPermission(
            id: .inputMonitoring,
            presentation: PermissionPresentation(
                titleKey: .permissionInputMonitoring,
                iconName: "keyboard",
                iconColorName: "orange",
                detailKeys: [
                    .permissionInputMonitoringDetail1,
                    .permissionInputMonitoringDetail2
                ]
            ),
            policy: PermissionPolicy(
                isRequired: false,
                settingsURL: PermissionCenter.inputMonitoringSettingsURL
            ),
            check: { previewDenied ? false : CGPreflightListenEventAccess() },
            requestPrompt: { CGRequestListenEventAccess() }
        )

        for permission in all {
            permission.onChange = { [weak self] _ in
                self?.updateState()
                self?.onChange?()
            }
        }
        updateState()
    }

    var isReady: Bool { required.allSatisfy(\.isGranted) }

    /// Starts the single poller.
    ///
    /// The interval is adaptive rather than fixed, because the two reasons to poll are
    /// different questions: while something is *missing*, the user is probably mid-flow and a
    /// grant could land at any moment (2s); once everything is granted, the only remaining
    /// event is a revocation, which costs a keypress or two of delay at 5s. One timer that
    /// re-arms itself at the interval the current state deserves, instead of two timers that
    /// overlap.
    func startPolling() {
        guard pollTimer == nil else { return }
        scheduleNextPoll()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func scheduleNextPoll() {
        pollTimer?.invalidate()
        let interval: TimeInterval = isReady ? 5.0 : 2.0
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshAll(noticedBy: "poll")
                self.scheduleNextPoll()
            }
        }
        timer.tolerance = interval * 0.2
        pollTimer = timer
    }

    /// The system posts this undocumented distributed notification when an app's Accessibility
    /// trust is toggled. Measured on macOS 27 it does *not* arrive when the entry is removed
    /// with Settings frontmost, so the poller is the one that actually notices a revocation —
    /// this stays because a stray posting is free and a working one would be faster.
    /// `refreshAll(noticedBy:)` is cheap and idempotent, and records which of them saw it.
    /// Input Monitoring has no equivalent notification at all, which is the other reason the
    /// poller stays.
    func startObservingSystemChanges() {
        guard systemChangeObserver == nil else { return }
        systemChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll(noticedBy: "notification") }
        }
    }

    func stopObservingSystemChanges() {
        if let systemChangeObserver {
            DistributedNotificationCenter.default().removeObserver(systemChangeObserver)
        }
        systemChangeObserver = nil
    }

    /// Re-reads every permission and reports what changed, with the reason it was checked.
    ///
    /// The reason matters more than it looks: revocation is the change with no reliable report
    /// of its own. The distributed notification is undocumented and, measured on macOS 27, did
    /// not arrive when the entry was removed with Settings frontmost; the activation and wake
    /// refreshes miss it because a menu-bar app is not frontmost while the user is in Settings.
    /// So `poll` is usually the one that notices — and the log should say so rather than
    /// leaving the next investigation to guess.
    func refreshAll(noticedBy reason: String) {
        for permission in all {
            permission.refresh(noticedBy: reason)
        }
        updateState()
    }

    private func updateState() {
        if all.allSatisfy(\.isGranted) {
            state = .allGranted
        } else if required.allSatisfy(\.isGranted) {
            state = .requiredGranted
        } else {
            state = .missing
        }
    }
}
