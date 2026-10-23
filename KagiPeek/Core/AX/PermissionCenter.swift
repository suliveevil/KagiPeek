import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

/// The two TCC permissions this app touches.
///
/// Accessibility is required: it powers both the menu-bar scan and the active event tap.
/// Input Monitoring is an optional fallback for setups where the tap still receives
/// nothing after Accessibility has been granted.
enum PermissionCenter {
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static var hasInputMonitoring: Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    /// True while the system is in secure keyboard entry (password fields, login window, …).
    static var isSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
