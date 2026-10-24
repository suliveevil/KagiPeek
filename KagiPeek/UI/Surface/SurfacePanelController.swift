import AppKit
import SwiftUI

final class SurfacePanel: NSPanel {
    /// Only the search palette may become key/mouse focus; the shortcut panel never does.
    var becomesKey = false

    override var canBecomeKey: Bool { becomesKey }
    override var canBecomeMain: Bool { false }
}

/// One window for both surfaces.
///
/// The shortcut panel and the search palette are mutually exclusive *and* share a single
/// NSPanel: switching swaps the hosting content, the size and whether the window may take
/// keyboard focus. There is never a second floating window.
@MainActor
final class SurfacePanelController {
    enum Mode {
        case hidden
        case panel
        case search
    }

    private let engine: ShortcutEngine
    private let panel: SurfacePanel

    private(set) var mode: Mode = .hidden
    private var anchorWindowFrame: CGRect?
    private var anchorPid: pid_t = 0
    private var outsideClickMonitor: Any?
    private var searchKeyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var contentInstalled = false

    init(engine: ShortcutEngine) {
        self.engine = engine
        panel = SurfacePanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow
    }

    var isVisible: Bool { mode != .hidden }

    /// The app that was frontmost before the search palette took focus.
    var searchTargetApplication: NSRunningApplication? { previousApp }

    /// What the palette's window is sending keys to.
    ///
    /// A focused `TextField` is served by its field editor — an `NSTextView` — which is what
    /// `/` checks before deciding whether it is a character or the way back to the panel.
    /// Exposed as a string so a log line can answer "why did `/` do that" without a debugger.
    var keyFocusDescription: String {
        let responder = panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        let typing = panel.firstResponder is NSTextView
        return "key=\(panel.isKeyWindow) active=\(NSApp.isActive) first=\(responder) typing=\(typing)"
    }

    // MARK: - Shortcut panel

    func presentPanel(state: PanelState, settings: AppSettingsSnapshot) {
        guard state.isVisible else {
            closePanel()
            return
        }

        ensureContent()
        if mode != .panel {
            switchToPanel()
        }

        if !isVisible || anchorPid != engine.frontmostProcessIdentifier {
            anchorPid = engine.frontmostProcessIdentifier
            anchorWindowFrame = WindowGeometry.focusedWindowFrame(pid: anchorPid)
                .map(WindowGeometry.cocoaRect(fromAX:))
        }

        let natural = OverlayMetrics.size(for: state, settings: settings)
        let screen = targetScreen()
        var size = panelSize(natural: natural, settings: settings, screen: screen)
        if settings.panelPlacement == .coverWindow {
            // A wider panel fits more columns, so the height must follow the final width.
            size.height = OverlayMetrics.size(for: state, settings: settings, width: size.width).height
        }
        panel.setContentSize(size)
        panel.setFrame(panelFrame(size: size, settings: settings, screen: screen), display: true)
        panel.orderFrontRegardless()
        installOutsideClickMonitor()
        // Armed every time the panel is drawn, because its frame moves with the list: the
        // tap has to know where the panel is before it can tell a click on the panel from a
        // click past it.
        engine.updateOutsideMouseSwallow(
            panelFrame: WindowGeometry.cgRect(fromCocoa: panel.frame),
            appWindowFrame: anchorWindowFrame.map(WindowGeometry.cgRect(fromCocoa:))
        )
    }

    func closePanel() {
        guard mode == .panel else { return }
        hide()
    }

    // MARK: - Search palette

    func presentSearch() {
        ensureContent()
        if mode != .search {
            if mode == .hidden {
                previousApp = NSWorkspace.shared.frontmostApplication
            }
            switchToSearch()
        }
        panel.setContentSize(NSSize(width: 680, height: 460))
        positionSearch()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        installSearchKeyMonitor()
        installOutsideClickMonitor()
    }

    func closeSearch() {
        guard mode == .search else { return }
        hide()
        restorePreviousAppIfNeeded()
    }

    func close() {
        switch mode {
        case .panel:
            closePanel()
        case .search:
            closeSearch()
        case .hidden:
            break
        }
    }

    // MARK: - Mode switching

    private func switchToPanel() {
        removeSearchKeyMonitor()
        if panel.isKeyWindow {
            panel.resignKey()
        }
        restorePreviousAppIfNeeded()
        mode = .panel
        panel.becomesKey = false
    }

    private func switchToSearch() {
        mode = .search
        panel.becomesKey = true
    }

    private func ensureContent() {
        guard !contentInstalled else { return }
        contentInstalled = true
        panel.contentView = NSHostingView(
            rootView: OverlayView()
                .environmentObject(engine)
                .environmentObject(engine.state)
                .environmentObject(engine.settingsStore)
                .environmentObject(engine.localization)
        )
    }

    private func hide() {
        mode = .hidden
        removeSearchKeyMonitor()
        removeOutsideClickMonitor()
        // Nothing is showing, so nothing is left to protect the app behind from.
        engine.updateOutsideMouseSwallow(panelFrame: nil, appWindowFrame: nil)
        panel.orderOut(nil)
    }

    private func restorePreviousAppIfNeeded() {
        guard NSApp.isActive, let previousApp, !previousApp.isTerminated else {
            self.previousApp = nil
            return
        }
        previousApp.activate()
        self.previousApp = nil
    }

    // MARK: - Search keyboard handling

    private func installSearchKeyMonitor() {
        guard searchKeyMonitor == nil else { return }
        searchKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            var handled = false
            MainActor.assumeIsolated {
                guard let self else { return }
                // While an input method is composing, Return commits candidates, arrows move
                // the candidate window and Escape cancels it. None of those belong to the
                // palette, so let the text field see the event untouched.
                if TextComposition.isComposing(in: self.panel) { return }
                // `/` is the way back to the panel on one condition: there is nothing to
                // search. An empty field means the round trip is over, so `/` closes it;
                // once something is typed, `/` is a character like any other — a search
                // field that refuses a slash mid-word is worse than a missing shortcut.
                // The query survives the trip, so the next `/` lands on the same search.
                // ⌘/ is never taken: that is macOS's Help shortcut.
                if event.keyCode == KeyCode.slash,
                   ModifierSet.from(flags: event.modifierFlags).isEmpty,
                   self.engine.state.search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.engine.returnToPanelFromSearch()
                    handled = true
                    return
                }
                // The event's real modifiers decide, not a hard-coded ⌃: passing `[.control]`
                // here made ⌃⌥P / ⌃⌘P look like navigation and swallowed them, while the
                // used to let the same combinations through.
                let modifiers = ModifierSet.from(flags: event.modifierFlags)
                if let direction = NavigationKey.direction(keyCode: event.keyCode, modifiers: modifiers) {
                    switch direction {
                    case .down: self.engine.moveSearchSelection(1)
                    case .up: self.engine.moveSearchSelection(-1)
                    case .left, .right:
                        // Leave caret movement to the text field.
                        return
                    }
                    handled = true
                    return
                }
                if event.keyCode == KeyCode.escape {
                    self.engine.hideSearch()
                    handled = true
                } else if event.keyCode == KeyCode.down {
                    self.engine.moveSearchSelection(1)
                    handled = true
                } else if event.keyCode == KeyCode.up {
                    self.engine.moveSearchSelection(-1)
                    handled = true
                }
            }
            return handled ? nil : event
        }
    }

    private func removeSearchKeyMonitor() {
        if let searchKeyMonitor {
            NSEvent.removeMonitor(searchKeyMonitor)
            self.searchKeyMonitor = nil
        }
    }

    // MARK: - Outside clicks

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                if !self.panel.frame.contains(NSEvent.mouseLocation) {
                    switch self.mode {
                    case .panel: self.engine.dismissPanel()
                    case .search: self.engine.hideSearch()
                    case .hidden: break
                    }
                }
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    // MARK: - Placement

    private func positionSearch() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 140
        ))
    }

    private func targetScreen() -> NSScreen? {
        if let anchor = anchorWindowFrame,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            return screen
        }
        return screenContainingMouse() ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func panelSize(natural: CGSize, settings: AppSettingsSnapshot, screen: NSScreen?) -> CGSize {
        guard let screen else { return natural }
        let visible = screen.visibleFrame
        switch settings.panelPlacement {
        case .fillScreen:
            return visible.size
        case .fixedSize:
            return CGSize(
                width: min(CGFloat(settings.fixedPanelWidth), visible.width),
                height: min(CGFloat(settings.fixedPanelHeight), visible.height)
            )
        case .coverWindow:
            guard let window = anchorWindowFrame else {
                return CGSize(width: visible.width * 0.8, height: visible.height * 0.7)
            }
            let halfWidth = max(abs(visible.midX - window.minX), abs(window.maxX - visible.midX)) + 24
            let halfHeight = max(abs(visible.midY - window.minY), abs(window.maxY - visible.midY)) + 24
            return CGSize(
                width: min(max(halfWidth * 2, natural.width), visible.width),
                height: min(max(halfHeight * 2, natural.height), visible.height)
            )
        case .besideWindow:
            return natural
        }
    }

    private func panelFrame(size: CGSize, settings: AppSettingsSnapshot, screen: NSScreen?) -> CGRect {
        guard let screen else { return CGRect(origin: .zero, size: size) }
        let visible = screen.visibleFrame
        switch settings.panelPlacement {
        case .fillScreen:
            return visible
        case .fixedSize, .coverWindow:
            return CGRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        case .besideWindow:
            return besideWindowFrame(size: size, screen: screen)
        }
    }

    private func besideWindowFrame(size: CGSize, screen: NSScreen) -> CGRect {
        let visible = screen.visibleFrame
        guard let anchor = anchorWindowFrame else {
            return clamp(
                CGRect(x: visible.maxX - size.width - 16, y: visible.maxY - size.height - 16, width: size.width, height: size.height),
                to: visible
            )
        }

        var candidate = CGRect(
            x: anchor.maxX + 12,
            y: anchor.maxY - size.height,
            width: size.width,
            height: size.height
        )
        if candidate.maxX > visible.maxX - 8 {
            candidate.origin.x = anchor.minX - size.width - 12
        }
        if candidate.minX < visible.minX + 8 {
            candidate.origin.x = anchor.minX + 16
            candidate.origin.y = anchor.minY - size.height - 12
        }
        candidate = clamp(candidate, to: visible)

        if let focused = WindowGeometry.focusedElementFrame(pid: anchorPid).map(WindowGeometry.cocoaRect(fromAX:)),
           focused.width > 1,
           candidate.intersects(focused) {
            var alternative = candidate
            alternative.origin.y = anchor.minY - size.height - 12
            if alternative.minY >= visible.minY + 8, !alternative.intersects(focused) {
                return clamp(alternative, to: visible)
            }
            alternative.origin.y = visible.minY + 8
            if !alternative.intersects(focused) {
                return clamp(alternative, to: visible)
            }
        }
        return candidate
    }

    private func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        var result = rect
        result.origin.x = min(max(result.origin.x, bounds.minX + 8), max(bounds.minX + 8, bounds.maxX - result.width - 8))
        result.origin.y = min(max(result.origin.y, bounds.minY + 8), max(bounds.minY + 8, bounds.maxY - result.height - 8))
        return result
    }

    private func screenContainingMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
    }
}
