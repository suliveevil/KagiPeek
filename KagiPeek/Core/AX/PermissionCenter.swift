import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// The two TCC permissions this app touches.
///
/// Accessibility is required: it powers both the menu-bar scan and the active event tap.
/// Input Monitoring is an optional fallback for setups where the tap still receives
/// nothing after Accessibility has been granted.
enum PermissionCenter {
    /// The only place the deep links are spelled out. The anchors are the System Settings
    /// (macOS 13+) identifiers — the pre-Ventura `com.apple.preference.security` spellings
    /// are unreliable on the OS versions this app supports.
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
    )
    static let inputMonitoringSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent"
    )

    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    static var hasInputMonitoring: Bool {
        CGPreflightListenEventAccess()
    }

    /// True while the system is in secure keyboard entry (password fields, login window, …).
    static var isSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }
}
