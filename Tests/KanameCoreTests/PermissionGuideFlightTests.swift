import XCTest
@testable import KanameCore

/// The entrance curve. Checked as geometry rather than as animation: the panel has to start
/// exactly where Kaname is and end exactly on the target, or the hand-off to the anchored
/// follow loop flickers by however much the last frame was off.
final class PermissionGuideFlightTests: XCTestCase {
    private let from = CGPoint(x: 400, y: 300)
    private let to = CGPoint(x: 900, y: 700)

    func testStartsExactlyAtTheSource() {
        let point = PermissionGuideFlight.point(progress: 0, from: from, to: to)
        XCTAssertEqual(point.x, from.x, accuracy: 0.001)
        XCTAssertEqual(point.y, from.y, accuracy: 0.001)
    }

    func testEndsExactlyOnTheTarget() {
        let point = PermissionGuideFlight.point(progress: 1, from: from, to: to)
        XCTAssertEqual(point.x, to.x, accuracy: 0.001)
        XCTAssertEqual(point.y, to.y, accuracy: 0.001)
    }

    func testTheArcPeaksAboveTheStraightLine() {
        // A level flight isolates the lift: with both ends on the same y, every point off
        // that y came from the parabola.
        let level = CGPoint(x: 900, y: from.y)
        let midpoint = PermissionGuideFlight.point(progress: 0.5, from: from, to: level)
        XCTAssertEqual(midpoint.y - from.y, PermissionGuideFlight.arcLift, accuracy: 0.001)
        for step in stride(from: CGFloat(0), through: 1, by: 0.05) {
            XCTAssertGreaterThanOrEqual(
                PermissionGuideFlight.point(progress: step, from: from, to: level).y,
                from.y - 0.001
            )
        }
    }

    func testTheArcOvershootsSlightlyAlongTheLine() {
        // The overshooting ease sails a few percent past the target before settling; the
        // largest x in the last third of the flight is past the target's.
        let peak = stride(from: CGFloat(0.6), through: 1.0, by: 0.02)
            .map { PermissionGuideFlight.point(progress: $0, from: from, to: to).x }
            .max() ?? 0
        XCTAssertGreaterThan(peak, to.x)
    }

    func testProgressIsClamped() {
        let before = PermissionGuideFlight.point(progress: -3, from: from, to: to)
        let after = PermissionGuideFlight.point(progress: 9, from: from, to: to)
        XCTAssertEqual(before.x, from.x, accuracy: 0.001)
        XCTAssertEqual(after.x, to.x, accuracy: 0.001)
    }

    func testScaleGrowsToFullSizeByTouchdown() {
        XCTAssertEqual(
            PermissionGuideFlight.scale(progress: 0),
            PermissionGuideFlight.startScale,
            accuracy: 0.0001
        )
        XCTAssertEqual(PermissionGuideFlight.scale(progress: PermissionGuideFlight.touchdown), 1, accuracy: 0.0001)
    }

    func testScalePopsAfterTouchdownAndSettlesBackToExactSize() {
        let afterTouchdown = (PermissionGuideFlight.touchdown + 0.3 * (1 - PermissionGuideFlight.touchdown))
        XCTAssertGreaterThan(PermissionGuideFlight.scale(progress: afterTouchdown), 1)
        // Exactly 1 at the end: anything else makes the panel snap when the animation ends.
        XCTAssertEqual(PermissionGuideFlight.scale(progress: 1), 1, accuracy: 0.0001)
    }

    func testScaleNeverDropsBelowItsStart() {
        for step in stride(from: CGFloat(0), through: 1, by: 0.01) {
            XCTAssertGreaterThanOrEqual(
                PermissionGuideFlight.scale(progress: step),
                PermissionGuideFlight.startScale - 0.0001
            )
        }
    }
}
