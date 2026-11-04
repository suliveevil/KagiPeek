import AppKit
import Foundation

/// What the engine needs from the windows, stated as protocols.
///
/// The engine used to build the four UI controllers itself — `lazy var surface =
/// SurfacePanelController(engine: self)` — and each controller took `engine: self` back. That
/// is a cycle in the type graph: `ShortcutEngine.swift` could not be checked without the whole
/// UI, because the UI was a compile-time dependency of Core. The dependency now runs
/// App → Core → these ports: Core names the protocols, `AppDelegate` builds the controllers
/// and hands them over as `EnginePresenters`, and the concrete classes stay in `UI/`.
///
/// The object graph is still mutual at runtime — a controller calls `engine.dismissPanel()`
/// when the user clicks away — and that is deliberate: what is gone is the *compile-time*
/// knowledge, which is what kept the engine untestable and unbuildable on its own.
///
/// Five protocols rather than one: a control that only needs the HUD should not be able to
/// open the settings window. Each is the shape of one window, so each has one reason to change.

/// The one floating surface: shortcut panel and search palette share it.
@MainActor
protocol PanelPresenting: AnyObject {
    /// Draw the panel for this state, or close it when `state.isVisible` is false.
    func presentPanel(state: PanelState, settings: AppSettingsSnapshot)
    func presentSearch()
    /// Close whichever surface is showing.
    func close()
    func closeSearch()
    /// The app that was frontmost before the palette took focus, for "run this there".
    var searchTargetApplication: NSRunningApplication? { get }
    /// What the palette's window is sending keys to — the `/` log line answers with it.
    var keyFocusDescription: String { get }
}

/// What the toast is saying. Success earns the `✓`; a failure must not carry a success
/// marker, and it stays on screen long enough to be read.
nonisolated enum NoticeKind: Sendable {
    case success
    case failure
    /// Explanatory, not an outcome: secure-input notices and similar.
    case info
}

/// The small confirmation window: a chord and a title, or one line of text.
@MainActor
protocol NoticePresenting: AnyObject {
    func show(chord: String, title: String, kind: NoticeKind)
    func showNotice(text: String, kind: NoticeKind)
}

extension NoticePresenting {
    func show(chord: String, title: String) {
        show(chord: chord, title: title, kind: .success)
    }

    func showNotice(text: String) {
        showNotice(text: text, kind: .info)
    }
}

@MainActor
protocol SettingsPresenting: AnyObject {
    func showSettings()
    /// Open the same window already showing the Conflicts page.
    func showConflicts()
}

@MainActor
protocol PermissionsPresenting: AnyObject {
    func showPermissions()
}

/// The drag-the-icon guide panel. It takes the localization with it because it draws itself
/// from a `permission` alone and keeps no reference to the engine.
@MainActor
protocol PermissionGuidePresenting: AnyObject {
    func presentPermissionGuide(_ permission: AppPermission, localization: Localization)
}

/// The five roles, handed to the engine once, at construction.
///
/// A struct rather than five parameters: the engine's `init` already takes its two stores,
/// and a five-parameter list of protocols would be the long-parameter-list smell in a new
/// place. The factory in `AppDelegate` is one expression the reader can check at a glance.
@MainActor
struct EnginePresenters {
    let panel: PanelPresenting
    let notices: NoticePresenting
    let settings: SettingsPresenting
    let permissions: PermissionsPresenting
    let guide: PermissionGuidePresenting
}
