import Foundation

/// The palette state a scope switch starts from, as a pure value.
///
/// `ShortcutEngine.selectSearchScope` used to clear six fields inline, then choose between
/// "loading" and "idle" depending on whether the app it was pointed at is running. That
/// sequence is a rule about the palette, not about AX or windows, so it lives here and the
/// engine only supplies the AppKit-only parts (the app's icon and process id).
nonisolated enum SearchScopePlan {
    /// The snapshot to publish when the user picks a scope, before its catalog arrives.
    ///
    /// - Parameters:
    ///   - appID: the chosen scope, or nil for the frontmost app.
    ///   - name: the chosen app's display name; ignored when the app is not running.
    ///   - isRunning: whether `appID` is one of the running apps. A scope pointing at an
    ///     app that is not running stays idle, exactly as the engine's guard did.
    static func switched(
        _ search: SearchSnapshot,
        appID: String?,
        name: String,
        isRunning: Bool
    ) -> SearchSnapshot {
        var next = search
        next.scopeAppID = appID
        next.scopeName = ""
        next.scopeItems = []
        next.usedBuiltInCatalog = false
        guard appID != nil, isRunning else {
            next.loadState = .idle
            return next
        }
        next.scopeName = name
        next.loadState = .loading
        return next
    }

    /// How a finished scoped scan's state reads in the palette.
    ///
    /// Everything except a denied permission is "ready": the scan may have produced an empty
    /// list, but it did answer, and an empty answer is different from one that never came.
    static func loadState(for state: ScanState) -> SearchLoadState {
        state == .permissionDenied ? .permissionDenied : .ready
    }
}
