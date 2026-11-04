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
///
/// Conforms to `PanelPresenting` (`Core/Ports/PresentationPorts.swift`) by having the same
/// method names: the engine drives this window through that protocol, and does not know it
/// exists.
@MainActor
final class SurfacePanelController: PanelPresenting {
    enum Mode {
        case hidden
        case panel
        case search
    }

    private let engine: ShortcutEngine
    private let panel: SurfacePanel

    private(set) var mode: Mode = .hidden
    /// Cocoa-coordinate snapshots of the anchor window and the focused element, refreshed
    /// off the main thread when the front app changes. Key presses only read these; they
    /// never call the AX API themselves.
    private var anchorWindowFrame: CGRect?
    private var focusedElementFrame: CGRect?
    private var anchorPid: pid_t = 0
    private var lastPanelSettings: AppSettingsSnapshot?
    private var geometryTask: Task<Void, Never>?
    private var isRefreshingGeometry = false
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

        lastPanelSettings = settings
        let pid = engine.frontmostProcessIdentifier
        if anchorPid != pid {
            // A new front app invalidates both snapshots. Read the replacements in the
            // background and cover the whole visible frame in the meantime: the previous
            // app's window would put the panel somewhere meaningless, and a shrunken guess
            // would leave the new window partly uncovered until the read returns.
            anchorPid = pid
            anchorWindowFrame = nil
            focusedElementFrame = nil
            refreshGeometry(for: pid)
        } else if anchorWindowFrame == nil {
            refreshGeometry(for: pid)
        }

        let screen = targetScreen()
        let size = panelSize(for: state, settings: settings, screen: screen)
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

    /// Reads the anchor/floating-element frames in the background and re-lays the panel out
    /// once they arrive. The content is swapped by `setContentSize` only, never rebuilt, so it
    /// does not flash or reorder; the frame settles onto the window that was just read.
    private func refreshGeometry(for pid: pid_t) {
        guard !isRefreshingGeometry else { return }
        isRefreshingGeometry = true
        geometryTask = Task { [weak self] in
            let snapshot = await PanelGeometryReader.read(pid: pid)
            guard let self else { return }
            self.isRefreshingGeometry = false
            guard self.anchorPid == pid else {
                // The front app changed while this read was in flight; get the new one.
                self.refreshGeometry(for: self.anchorPid)
                return
            }
            self.anchorWindowFrame = snapshot.windowFrame.map(WindowGeometry.cocoaRect(fromAX:))
            self.focusedElementFrame = snapshot.focusedElementFrame.map(WindowGeometry.cocoaRect(fromAX:))
            guard self.mode != .hidden else { return }
            switch self.mode {
            case .panel:
                guard let settings = self.lastPanelSettings else { return }
                // The frame that arrived may be the first one for this app, so the panel was
                // drawn from the fallback size. Recompute it here as well: repositioning the
                // fallback left a tall window uncovered until the next `presentPanel`.
                let screen = self.targetScreen()
                let size = self.panelSize(for: self.engine.state.panel, settings: settings, screen: screen)
                self.panel.setContentSize(size)
                self.panel.setFrame(
                    self.panelFrame(size: size, settings: settings, screen: screen),
                    display: true
                )
                self.engine.updateOutsideMouseSwallow(
                    panelFrame: WindowGeometry.cgRect(fromCocoa: self.panel.frame),
                    appWindowFrame: self.anchorWindowFrame.map(WindowGeometry.cgRect(fromCocoa:))
                )
            case .search:
                // The frame arrived after the palette was placed from the fallback; move it
                // onto the window now that the real frame is known.
                guard let visible = self.targetScreen()?.visibleFrame else { return }
                let size = OverlayPlacement.searchSize(windowFrame: self.anchorWindowFrame, visible: visible)
                self.panel.setContentSize(size)
                self.panel.setFrame(
                    OverlayPlacement.searchFrame(windowFrame: self.anchorWindowFrame, visible: visible, size: size),
                    display: true
                )
            case .hidden:
                break
            }
        }
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
        // Read the target pid before `NSApp.activate()`: afterwards the frontmost app is
        // KagiPeek itself, and its window frame is not what the palette should centre on.
        let pid = previousApp.map(\.processIdentifier) ?? engine.frontmostProcessIdentifier
        if anchorPid != pid || anchorWindowFrame == nil {
            anchorPid = pid
            anchorWindowFrame = nil
            focusedElementFrame = nil
            refreshGeometry(for: pid)
        }
        let screen = targetScreen()
        let size: CGSize
        let frame: CGRect
        if let visible = screen?.visibleFrame {
            size = OverlayPlacement.searchSize(windowFrame: anchorWindowFrame, visible: visible)
            frame = OverlayPlacement.searchFrame(windowFrame: anchorWindowFrame, visible: visible, size: size)
        } else {
            size = CGSize(width: OverlayPlacement.searchWidth, height: OverlayPlacement.searchMinHeight)
            frame = CGRect(origin: .zero, size: size)
        }
        panel.setContentSize(size)
        panel.setFrame(frame, display: true)
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
                .environmentObject(engine.usageStore)
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
                // The key-by-key decision is pure and tested (`SearchKeyRouter`); here we only
                // run the action it returns.
                let modifiers = ModifierSet.from(flags: event.modifierFlags)
                let isQueryEmpty = self.engine.state.search.query
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                switch SearchKeyRouter.action(
                    keyCode: event.keyCode,
                    modifiers: modifiers,
                    isQueryEmpty: isQueryEmpty,
                    characters: event.characters
                ) {
                case .moveSelection(let delta):
                    self.engine.moveSearchSelection(delta)
                    handled = true
                case .close:
                    self.engine.hideSearch()
                    handled = true
                case .returnToPanel:
                    self.engine.returnToPanelFromSearch()
                    handled = true
                case .passThrough:
                    break
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

    private func targetScreen() -> NSScreen? {
        if let anchor = anchorWindowFrame,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) {
            return screen
        }
        return screenContainingMouse() ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The panel's frame size for a given state, including the cover-height correction.
    private func panelSize(for state: PanelState, settings: AppSettingsSnapshot, screen: NSScreen?) -> CGSize {
        let natural = OverlayMetrics.size(for: state, settings: settings)
        var size = placementSize(natural: natural, settings: settings, screen: screen)
        if settings.panelPlacement == .coverWindow {
            // A wider panel fits more columns, so the content height follows the final width —
            // but the cover height must survive that. Taking the larger of the two keeps the
            // window covered; a panel that shrank to its content stopped covering a tall window.
            let contentHeight = OverlayMetrics.size(for: state, settings: settings, width: size.width).height
            size.height = OverlayPlacement.coveredHeight(
                contentHeight: contentHeight,
                coverHeight: size.height,
                limit: screen?.visibleFrame.height ?? size.height
            )
        }
        return size
    }

    private func placementSize(natural: CGSize, settings: AppSettingsSnapshot, screen: NSScreen?) -> CGSize {
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
                // The front window's frame arrives asynchronously, so the first frame after an
                // app switch has no window to cover. A shrunken guess left the window half
                // exposed; the visible frame covers every window, so start there and settle
                // onto the window once its frame is known.
                return visible.size
            }
            return OverlayPlacement.coverWindowSize(windowFrame: window, visible: visible, natural: natural)
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
            return OverlayPlacement.containedFrame(
                CGRect(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                in: visible
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

        if let focused = focusedElementFrame,
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
        OverlayPlacement.containedFrame(rect, in: bounds)
    }

    private func screenContainingMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) }
    }
}
