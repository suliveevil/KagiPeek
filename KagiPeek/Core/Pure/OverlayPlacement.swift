import CoreGraphics

/// Frames both surfaces resolve against the front window and the visible screen area.
///
/// Pure on purpose: "does the panel still cover the window when the content shrinks" is
/// invisible in a screenshot (the screenshot is taken at the size it produced) and obvious
/// in an assertion.
nonisolated enum OverlayPlacement {
    /// Breathing room kept beyond the window on each side, so the panel's edge never lands
    /// exactly on the window's edge.
    static let coverMargin: CGFloat = 24
    /// The palette keeps its width; only its height follows the front window.
    static let searchWidth: CGFloat = 680
    static let searchMinHeight: CGFloat = 460

    /// The size that covers `windowFrame` when centred on `visible`'s centre.
    ///
    /// Each dimension is measured from the centre to the farther window edge, so being
    /// centred already guarantees containment even when the window sits off to one side.
    static func coverWindowSize(windowFrame: CGRect, visible: CGRect, natural: CGSize) -> CGSize {
        let halfWidth = max(abs(visible.midX - windowFrame.minX), abs(windowFrame.maxX - visible.midX))
            + coverMargin
        let halfHeight = max(abs(visible.midY - windowFrame.minY), abs(windowFrame.maxY - visible.midY))
            + coverMargin
        return CGSize(
            width: min(max(halfWidth * 2, natural.width), visible.width),
            height: min(max(halfHeight * 2, natural.height), visible.height)
        )
    }

    /// The cover height wins over the content height: widening the panel can need fewer
    /// rows, but a panel shorter than the window stops covering it.
    static func coveredHeight(contentHeight: CGFloat, coverHeight: CGFloat, limit: CGFloat) -> CGFloat {
        min(max(coverHeight, contentHeight), limit)
    }

    /// Breathing room between a panel and the screen edge.
    static let screenMargin: CGFloat = 8

    /// Moves a frame inside `visible` instead of letting it hang off the edge.
    ///
    /// A panel anchored near the bottom of the screen can have its last rows cut by the
    /// display, which is the one place the user cannot scroll to. The frame is shifted as
    /// a whole — never stretched or clipped — so the footer and the rows below it stay
    /// where they were relative to each other.
    static func containedFrame(_ frame: CGRect, in visible: CGRect) -> CGRect {
        var result = frame
        result.origin.x = min(
            max(result.origin.x, visible.minX + screenMargin),
            max(visible.minX + screenMargin, visible.maxX - result.width - screenMargin)
        )
        result.origin.y = min(
            max(result.origin.y, visible.minY + screenMargin),
            max(visible.minY + screenMargin, visible.maxY - result.height - screenMargin)
        )
        return result
    }

    /// The palette is `searchWidth` wide and at least as tall as the front window, so it
    /// spans the window instead of hugging the top of the screen.
    static func searchSize(windowFrame: CGRect?, visible: CGRect) -> CGSize {
        let width = min(searchWidth, visible.width)
        guard let windowFrame else {
            return CGSize(width: width, height: min(searchMinHeight, visible.height))
        }
        return CGSize(
            width: width,
            height: min(max(searchMinHeight, windowFrame.height), visible.height)
        )
    }

    /// Centred on the front window and clamped inside the visible frame; screen-centred only
    /// when there is no window frame to anchor to.
    static func searchFrame(windowFrame: CGRect?, visible: CGRect, size: CGSize) -> CGRect {
        let center = windowFrame.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: visible.midX, y: visible.midY)
        let x = min(max(center.x - size.width / 2, visible.minX), max(visible.minX, visible.maxX - size.width))
        let y = min(max(center.y - size.height / 2, visible.minY), max(visible.minY, visible.maxY - size.height))
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
