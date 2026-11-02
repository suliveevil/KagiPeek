import AppKit
import Combine
import Foundation

/// One system permission KagiPeek may need.
///
/// Modelled after the permission cards in Thaw (thaw-app/Thaw): a title, an icon, the
/// concrete things the permission enables, whether it is required, the exact settings pane,
/// and a 3-second poll that stops as soon as the grant is detected.
@MainActor
final class AppPermission: ObservableObject, Identifiable {
    enum Identifier: String {
        case accessibility
        case inputMonitoring
    }

    let id: Identifier
    let titleKey: L10nKey
    let iconName: String
    let iconColorName: String
    let detailKeys: [L10nKey]
    let isRequired: Bool
    let settingsURL: URL?
    /// Whether asking for this permission through the system API adds the app to the list
    /// **switched off**.
    ///
    /// Accessibility is that case: `AXIsProcessTrustedWithOptions(prompt:)` registers the
    /// app before the user has done anything, and a registered-but-off entry is exactly the
    /// state the drag-instruction cannot fix — dragging it in again is how you end up with
    /// the "already listed but the switch won't stick" support question. LobeHub's desktop
    /// guide dropped the pre-registration for the same reason, so the guided flow opens
    /// System Settings and lets the drop both add *and* enable the entry.
    let promptPreRegisters: Bool

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
    private var timer: Timer?

    init(
        id: Identifier,
        titleKey: L10nKey,
        iconName: String,
        iconColorName: String,
        detailKeys: [L10nKey],
        isRequired: Bool,
        settingsURL: URL?,
        promptPreRegisters: Bool = false,
        check: @escaping () -> Bool,
        requestPrompt: @escaping () -> Bool
    ) {
        self.id = id
        self.titleKey = titleKey
        self.iconName = iconName
        self.iconColorName = iconColorName
        self.detailKeys = detailKeys
        self.isRequired = isRequired
        self.settingsURL = settingsURL
        self.promptPreRegisters = promptPreRegisters
        self.check = check
        self.requestPrompt = requestPrompt
        self.isGranted = check()
    }

    func refresh() {
        let granted = check()
        guard granted != isGranted else { return }
        isGranted = granted
        if granted {
            stopPolling()
            guideStatus = .idle
        }
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
        startPolling()
        if !promptPreRegisters {
            _ = requestPrompt()
        }
        openSettingsPane()
    }

    /// Opens the pane and raises Settings.
    ///
    /// The raise is explicit because a deep link does not bring an already-running Settings
    /// forward — without it the guide floats over whatever the user was looking at.
    func openSettingsPane() {
        if let settingsURL {
            NSWorkspace.shared.open(settingsURL)
        }
        SettingsWindowLocator.activateSettings()
        onSettingsPaneOpened?()
    }

    func startPolling() {
        guard timer == nil, !isGranted else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        self.timer = timer
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
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
    private var revocationTimer: Timer?

    var all: [AppPermission] { [accessibility, inputMonitoring] }
    var required: [AppPermission] { all.filter(\.isRequired) }

    init(previewDenied: Bool = false) {
        accessibility = AppPermission(
            id: .accessibility,
            titleKey: .permissionAccessibility,
            iconName: "accessibility",
            iconColorName: "blue",
            detailKeys: [
                .permissionAccessibilityDetail1,
                .permissionAccessibilityDetail2,
                .permissionAccessibilityDetail3
            ],
            isRequired: true,
            settingsURL: PermissionCenter.accessibilitySettingsURL,
            promptPreRegisters: true,
            check: { previewDenied ? false : AXIsProcessTrusted() },
            requestPrompt: {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                return AXIsProcessTrustedWithOptions(options)
            }
        )

        inputMonitoring = AppPermission(
            id: .inputMonitoring,
            titleKey: .permissionInputMonitoring,
            iconName: "keyboard",
            iconColorName: "orange",
            detailKeys: [
                .permissionInputMonitoringDetail1,
                .permissionInputMonitoringDetail2
            ],
            isRequired: false,
            settingsURL: PermissionCenter.inputMonitoringSettingsURL,
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

    func startPolling() {
        for permission in all where !permission.isGranted {
            permission.startPolling()
        }
    }

    func stopPolling() {
        for permission in all {
            permission.stopPolling()
        }
    }

    /// The system posts this undocumented distributed notification when an app's Accessibility
    /// trust is toggled, which is the only way to notice a revocation while KagiPeek keeps
    /// running: the 3-second polls stop once a grant is detected. `refreshAll()` is cheap and
    /// idempotent, so a stray posting costs nothing. The polls and the activation/wake
    /// refreshes stay as fallbacks for the day the name stops being posted — and for Input
    /// Monitoring, which has no equivalent notification.
    func startObservingSystemChanges() {
        guard systemChangeObserver == nil else { return }
        systemChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
    }

    func stopObservingSystemChanges() {
        if let systemChangeObserver {
            DistributedNotificationCenter.default().removeObserver(systemChangeObserver)
        }
        systemChangeObserver = nil
    }

    /// Watches for a permission being *taken away*.
    ///
    /// `startPolling()` is the other half and cannot do this job: it runs only while a
    /// permission is missing, and it stops the moment one is granted — which is exactly the
    /// state a revocation starts from. The distributed notification above is undocumented
    /// and, measured on macOS 27, did not arrive when the entry was removed with Settings
    /// frontmost; the activation and wake refreshes miss it too, because a menu-bar app is
    /// not frontmost while the user is in Settings. The gap is not cosmetic: a revoked
    /// Accessibility leaves the event tap installed and unanswerable, and every keypress in
    /// the session then waits out the tap's timeout.
    ///
    /// What runs here is two local boolean checks every five seconds — a grant costs nothing
    /// to confirm and nothing happens when it is unchanged.
    func startRevocationWatch() {
        guard revocationTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
        timer.tolerance = 2.0
        revocationTimer = timer
    }

    func stopRevocationWatch() {
        revocationTimer?.invalidate()
        revocationTimer = nil
    }

    func refreshAll() {
        for permission in all {
            permission.refresh()
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
