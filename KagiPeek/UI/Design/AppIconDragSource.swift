import AppKit
import SwiftUI

/// The app icon as a real drag source, started the way Finder — and LobeHub's macOS
/// permission guide — start one.
///
/// SwiftUI's `.onDrag` hands the system an `NSItemProvider`, and an item provider cannot
/// advertise `NSFilenamesPboardType`, the legacy "array of paths" flavour that older drop
/// targets still read. System Settings' privacy lists are one of those: the pointer shows a
/// **+** (a registered type matched) and the drop adds nothing. Adding the app by hand with
/// **+** works, which is what pinned the fault to the payload rather than to the bundle.
///
/// A dragging session with the `URL` itself as the pasteboard writer writes exactly what
/// Finder writes — `public.file-url`, `NSFilenamesPboardType` and the URL flavours.
/// LobeHub's `LobeGuideIconView` (`packages/electron-mac-permission-guide/native/addon.mm`)
/// does the same, and the details below are taken from it because every one of them is
/// load-bearing: an empty `mouseDown`, the drag event (not the mouse-down) passed to the
/// session, the operation mask including link and generic, and `mouseDownCanMoveWindow`
/// answering no so a drag inside the panel never turns into a window move.
struct AppIconDragSource: NSViewRepresentable {
    var side: CGFloat
    var bundleURL: URL

    func makeNSView(context: Context) -> AppIconDragView {
        let view = AppIconDragView()
        view.dragURL = bundleURL
        return view
    }

    func updateNSView(_ view: AppIconDragView, context: Context) {
        view.dragURL = bundleURL
    }
}

/// Draws the app icon and starts the drag. A non-activating panel is never key, so
/// `acceptsFirstMouse` has to say yes or the first press would be spent waking the window.
final class AppIconDragView: NSView, NSDraggingSource {
    var dragURL: URL? {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    private var dragging = false
    private var icon: NSImage { NSApp.applicationIconImage }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.masksToBounds = true
        layer?.contents = NSApp.applicationIconImage
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        // The app icon is a square bitmap; rounding it here is what keeps the drag source
        // looking like the real icon rather than a screenshot of one.
        layer?.cornerRadius = bounds.width * 0.23
        layer?.contents = icon
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Without this, a press-and-drag inside the panel moves the window instead of starting
    /// a drag session — the icon simply would not come off the panel.
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        guard dragURL != nil else { return }
        addCursorRect(bounds, cursor: .openHand)
    }

    /// Deliberately empty: the drag starts on `mouseDragged`, and nothing should happen on a
    /// plain click.
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let dragURL, !dragging else { return }
        dragging = true

        // The URL is the pasteboard writer, which is the whole point: it writes
        // `public.file-url` **and** `NSFilenamesPboardType`.
        let item = NSDraggingItem(pasteboardWriter: dragURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)

        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    // MARK: - NSDraggingSource

    /// Copy *and* link and generic: a privacy list that only accepts one of the latter two
    /// would otherwise see `none` and refuse the drop.
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        [.copy, .link, .generic]
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        dragging = false
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
