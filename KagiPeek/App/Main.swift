import AppKit

/// AppKit entry point.
///
/// The app used to be a SwiftUI `App` whose only scene was a `MenuBarExtra`. Two problems
/// came with that scene, and both were visible from the outside:
///
/// * the menu bar item was handed to the system with no handle back, so when macOS or a menu
///   bar manager (Thaw, Ice, Bartender…) dropped or re-parented it, the app could not tell and
///   the icon was gone while the process kept running;
/// * the replacement `Settings` scene presented an empty window at launch.
///
/// An agent that owns its `NSStatusItem` has no use for scenes. Everything the app shows is an
/// `NSWindowController` opened on demand.
@main
enum KagiPeekMain {
    /// `NSApplication.delegate` is a weak reference: without this, the delegate would be
    /// deallocated right after `run()` starts and the app would come up with no behaviour.
    @MainActor private static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
