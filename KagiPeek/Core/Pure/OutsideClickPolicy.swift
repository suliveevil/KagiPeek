import Foundation

/// A rectangle in screen coordinates, in the same origin convention as the caller.
///
/// Plain numbers rather than `CGRect` so this rule can be asserted without a graphics
/// library in the room.
struct ScreenRect: Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px < x + width && py >= y && py < y + height
    }
}

/// Whether a mouse press has to be eaten.
///
/// Dismissing the panel by clicking away used to close it *and* click whatever sat behind it
/// in the app the user was working in — moving the insertion point, changing the selection,
/// pressing a button they never aimed at. Closing the panel is one gesture, not two.
///
/// But only that gesture. A press anywhere else is the user reaching for something else —
/// the menu bar, the Dock, the desktop, another app's window — and swallowing it would make
/// the panel feel like it had frozen the screen. So the rule is a place, not a state: inside
/// the front app's window, outside the panel.
enum OutsideClickPolicy {
    static func shouldSwallow(
        point: (x: Double, y: Double),
        panel: ScreenRect,
        app: ScreenRect
    ) -> Bool {
        app.contains(x: point.x, y: point.y) && !panel.contains(x: point.x, y: point.y)
    }
}
