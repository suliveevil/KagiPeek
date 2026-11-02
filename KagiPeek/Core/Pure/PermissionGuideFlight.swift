import CoreGraphics
import Foundation

/// The guide panel's entrance: it leaves the KagiPeek window the user just clicked in and
/// lands on the System Settings window along a parabolic arc.
///
/// LobeHub's desktop guide drives this with closed-form damped springs; the shape that
/// matters is the same and is what this file encodes: zero velocity at the start, a small
/// overshoot along the line to the target, a lift that peaks mid-flight and is gone by
/// touchdown, and a scale pop that peaks just after touchdown and settles back to 1 — so
/// the panel never jumps when the animation hands over to the plain anchored position.
///
/// Pure math on plain points: the controller owns the timer, the screen queries and the
/// Reduce Motion decision.
enum PermissionGuideFlight {
    /// How long the whole entrance takes.
    static let duration: TimeInterval = 0.6

    /// Fraction of `duration` at which the panel is on target and only the scale settles.
    static let touchdown: CGFloat = 0.78

    /// How far above the straight line the arc peaks, in points.
    static let arcLift: CGFloat = 64

    /// The scale the panel starts at, before it grows to its full size.
    static let startScale: CGFloat = 0.94

    /// Peak of the overshoot after touchdown.
    static let popAmplitude: CGFloat = 0.07

    /// Position along the arc at `progress` (0…1, clamped).
    ///
    /// The straight-line part uses an overshooting ease so the panel sails a few percent
    /// past the target before settling onto it, and the lift is a parabola that is zero at
    /// both ends — so 0 is exactly `from` and 1 is exactly `to`, which is what keeps the
    /// first and last frames from flicking.
    static func point(progress: CGFloat, from: CGPoint, to: CGPoint) -> CGPoint {
        let u = clamp(progress)
        let travel = easeOutBack(u)
        let x = from.x + (to.x - from.x) * travel
        var y = from.y + (to.y - from.y) * travel
        // AppKit screen coordinates put "up" at +y.
        y += arcLift * 4 * u * (1 - u)
        return CGPoint(x: x, y: y)
    }

    /// The panel's scale at `progress`: grows to 1 by touchdown, then pops slightly past it
    /// and decays back to exactly 1.
    static func scale(progress: CGFloat) -> CGFloat {
        let u = clamp(progress)
        guard u > touchdown else {
            let grown = u / touchdown
            return startScale + (1 - startScale) * easeOutCubic(grown)
        }
        let over = (u - touchdown) / (1 - touchdown)
        return 1 + popAmplitude * sin(over * .pi) * (1 - over)
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    private static func easeOutCubic(_ u: CGFloat) -> CGFloat {
        let inverted = 1 - u
        return 1 - inverted * inverted * inverted
    }

    /// Ends at exactly 1 while sailing past it in the middle: the classic "it lands with a
    /// little weight" curve.
    private static func easeOutBack(_ u: CGFloat) -> CGFloat {
        let overshoot: CGFloat = 1.24
        let shifted = u - 1
        return 1 + (overshoot + 1) * shifted * shifted * shifted + overshoot * shifted * shifted
    }
}
