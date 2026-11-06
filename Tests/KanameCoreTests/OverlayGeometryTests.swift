import CoreGraphics
import XCTest
@testable import KanameCore

/// The notch and the menu bar live in the screen's top safe area. A panel that ignores it
/// draws its top rows underneath them, which is the same class of bug as a hidden footer:
/// pure arithmetic, so it is asserted rather than screenshotted.
final class OverlayGeometryTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testTopInsetFallsBackToTheScreenMargin() {
        XCTAssertEqual(OverlayPlacement.topInset(safeAreaTop: 0), OverlayPlacement.screenMargin)
        XCTAssertEqual(OverlayPlacement.topInset(safeAreaTop: 32), 32)
    }

    /// The fill-screen panel trims its top, never its origin: the footer keeps its place.
    func testFillScreenFrameTrimsTheTopOnly() {
        let frame = OverlayPlacement.fillScreenFrame(visible: screen, safeAreaTop: 32)
        XCTAssertEqual(frame.origin, screen.origin)
        XCTAssertEqual(frame.size.width, screen.width)
        XCTAssertEqual(frame.size.height, screen.height - 32)
    }

    func testClampedTopPushesTheFrameBelowTheSafeAreaWithoutResizing() {
        let frame = CGRect(x: 100, y: 500, width: 600, height: 500)
        let result = OverlayPlacement.clampedTop(frame, in: screen, safeAreaTop: 32)
        XCTAssertEqual(result.maxY, screen.maxY - 32)
        XCTAssertEqual(result.size, frame.size)
    }

    /// A display without a notch must not gain a bigger margin than the regular one.
    func testNoNotchProducesAtMostTheScreenMargin() {
        let frame = CGRect(x: 100, y: 700, width: 600, height: 500)
        let result = OverlayPlacement.clampedTop(frame, in: screen, safeAreaTop: 0)
        XCTAssertLessThanOrEqual(result.maxY, screen.maxY - OverlayPlacement.screenMargin)
        XCTAssertEqual(result.maxY, screen.maxY - OverlayPlacement.screenMargin)
        XCTAssertEqual(result.size, frame.size)
    }

    /// A frame already below the safe area is left alone.
    func testFrameBelowTheSafeAreaIsNotMoved() {
        let frame = CGRect(x: 100, y: 100, width: 600, height: 500)
        XCTAssertEqual(OverlayPlacement.clampedTop(frame, in: screen, safeAreaTop: 32), frame)
    }
}
