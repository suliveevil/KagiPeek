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

    @Published private(set) var isGranted: Bool

    var onChange: ((Bool) -> Void)?

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
        self.check = check
        self.requestPrompt = requestPrompt
        self.isGranted = check()
    }

    func refresh() {
        let granted = check()
        guard granted != isGranted else { return }
        isGranted = granted
        if granted { stopPolling() }
        onChange?(granted)
    }

    /// Fire the system prompt *and* open the matching System Settings pane, so the flow can
    /// be recovered if the user closes System Settings without granting.
    func performRequest() {
        startPolling()
        _ = requestPrompt()
        openSettingsPane()
    }

    func openSettingsPane() {
        if let settingsURL {
            NSWorkspace.shared.open(settingsURL)
        }
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
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
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
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"),
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
