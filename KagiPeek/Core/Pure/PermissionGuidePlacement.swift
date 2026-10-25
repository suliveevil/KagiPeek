import CoreGraphics
import Foundation

/// Geometry for the permission drag guide — the horizontal bar that hugs the System
/// Settings window's bottom-right corner so the app icon can be dropped straight into the
/// permission list (the interaction iScroll popularized).
///
/// Pure math on plain rects: the AppKit side owns the window lookup and screen queries,
/// so every rule here — the CG→AppKit flip, below/above stacking, edge clamping — stays
/// testable without a live System Settings window.
enum PermissionGuidePlacement {
    /// Gap between the Settings window and the guide panel.
    static let margin: CGFloat = 12

    /// Flips a window rect from global CG coordinates (origin top-left) into AppKit screen
    /// coordinates (origin bottom-left). `appKitTopY` is the AppKit y of CG y=0: the highest
    /// top edge among the connected screens.
    static func appKitFrame(ofCGFrame cgFrame: CGRect, appKitTopY: CGFloat) -> CGRect {
        CGRect(
            x: cgFrame.minX,
            y: appKitTopY - cgFrame.maxY,
            width: cgFrame.width,
            height: cgFrame.height
        )
    }

    /// Where the guide bar sits for a given Settings window frame.
    ///
    /// Hugging the Settings window's bottom-right corner: right edges aligned, the bar
    /// directly under the window — right where the list's add/remove controls live, so
    /// the icon sits beside the drop target. When the space below is exhausted the bar
    /// stacks above the window instead (right edges still aligned), and either way the
    /// result is clamped into `visibleFrame`, so a Settings window at a screen border
    /// still yields an origin that keeps the whole bar on screen.
    static func anchoredOrigin(
        panelSize: CGSize,
        settingsFrame: CGRect,
        visibleFrame: CGRect,
        margin: CGFloat = margin
    ) -> CGPoint {
        let belowY = settingsFrame.minY - margin - panelSize.height
        let isBelow = belowY >= visibleFrame.minY
        let y = isBelow ? belowY : settingsFrame.maxY + margin

        let rightAlignedX = settingsFrame.maxX - panelSize.width
        let x = rightAlignedX

        let clampedX = min(max(x, visibleFrame.minX), visibleFrame.maxX - panelSize.width)
        let clampedY = min(max(y, visibleFrame.minY), visibleFrame.maxY - panelSize.height)
        return CGPoint(x: clampedX, y: clampedY)
    }
}
