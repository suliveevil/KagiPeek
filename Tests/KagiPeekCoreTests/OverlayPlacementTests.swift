import CoreGraphics
import XCTest
@testable import KagiPeekCore

/// The panel must still cover the front window after the content shrinks, and the palette
/// must sit on that window rather than on the screen. Both are frame arithmetic, so they
/// are asserted here instead of in a screenshot that would be taken at the size it produced.
final class OverlayPlacementTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let screenCentre = CGPoint(x: 720, y: 450)

    private func centred(_ size: CGSize, in rect: CGRect) -> CGRect {
        CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Hint panel

    func testCoverSizeCoversAnOffCentreWindowInBothDimensions() {
        let window = CGRect(x: 120, y: 80, width: 900, height: 700)
        let natural = CGSize(width: 680, height: 300)
        let size = OverlayPlacement.coverWindowSize(windowFrame: window, visible: visible, natural: natural)
        let frame = centred(size, in: visible)

        XCTAssertTrue(frame.contains(window), "panel \(frame) does not cover window \(window)")
        XCTAssertEqual(frame.midX, screenCentre.x)
        XCTAssertEqual(frame.midY, screenCentre.y)
        XCTAssertGreaterThan(size.height, natural.height, "the cover height must beat the content height")
    }

    func testCoverSizeNeverShrinksBelowNaturalSize() {
        let window = CGRect(x: 700, y: 440, width: 40, height: 20)
        let natural = CGSize(width: 680, height: 520)
        let size = OverlayPlacement.coverWindowSize(windowFrame: window, visible: visible, natural: natural)

        XCTAssertGreaterThanOrEqual(size.width, natural.width)
        XCTAssertGreaterThanOrEqual(size.height, natural.height)
    }

    func testCoverSizeIsCappedToTheVisibleFrame() {
        let window = CGRect(x: -200, y: -100, width: 2000, height: 1200)
        let size = OverlayPlacement.coverWindowSize(windowFrame: window, visible: visible, natural: CGSize(width: 680, height: 300))

        XCTAssertEqual(size.width, visible.width)
        XCTAssertEqual(size.height, visible.height)
    }

    func testCoveredHeightKeepsTheTallerOfContentAndCover() {
        XCTAssertEqual(
            OverlayPlacement.coveredHeight(contentHeight: 300, coverHeight: 788, limit: 900),
            788,
            "a wider, shorter list must not shrink the window below the cover height"
        )
        XCTAssertEqual(
            OverlayPlacement.coveredHeight(contentHeight: 700, coverHeight: 400, limit: 900),
            700
        )
        XCTAssertEqual(
            OverlayPlacement.coveredHeight(contentHeight: 300, coverHeight: 400, limit: 320),
            320,
            "the result still has to fit the visible frame"
        )
    }

    func testFullscreenWindowFillsTheVisibleFrame() {
        // In native fullscreen the visible frame is the whole screen, so the 24 pt margin
        // has nowhere to go: the panel ends up exactly the size of the screen and still covers.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = OverlayPlacement.coverWindowSize(
            windowFrame: screen,
            visible: screen,
            natural: CGSize(width: 680, height: 300)
        )
        let frame = centred(size, in: screen)

        XCTAssertEqual(size, screen.size)
        XCTAssertEqual(frame, screen)
        XCTAssertTrue(frame.contains(screen))
    }

    // MARK: - Search palette

    func testSearchSizeFollowsTheWindowHeightAndKeepsItsWidth() {
        let window = CGRect(x: 200, y: 50, width: 800, height: 760)
        let size = OverlayPlacement.searchSize(windowFrame: window, visible: visible)

        XCTAssertEqual(size.width, OverlayPlacement.searchWidth)
        XCTAssertEqual(size.height, 760, "the palette spans the window instead of a fixed 460")
    }

    func testSearchSizeFallsBackToTheMinimumWithoutAWindow() {
        let size = OverlayPlacement.searchSize(windowFrame: nil, visible: visible)

        XCTAssertEqual(size.width, OverlayPlacement.searchWidth)
        XCTAssertEqual(size.height, OverlayPlacement.searchMinHeight)
    }

    func testSearchSizeIsCappedToTheVisibleFrame() {
        let window = CGRect(x: 0, y: 0, width: 1440, height: 1400)
        let size = OverlayPlacement.searchSize(windowFrame: window, visible: visible)

        XCTAssertEqual(size.height, visible.height)
    }

    func testSearchFrameIsCentredOnTheWindowNotTheScreen() {
        let window = CGRect(x: 100, y: 100, width: 700, height: 600)
        let size = OverlayPlacement.searchSize(windowFrame: window, visible: visible)
        let frame = OverlayPlacement.searchFrame(windowFrame: window, visible: visible, size: size)

        XCTAssertEqual(frame.midX, window.midX)
        XCTAssertEqual(frame.midY, window.midY)
        XCTAssertNotEqual(frame.midX, screenCentre.x)
        XCTAssertNotEqual(frame.midY, screenCentre.y)
    }

    func testSearchFrameStaysInsideTheVisibleFrameWhenTheWindowHugsAnEdge() {
        let window = CGRect(x: 0, y: 0, width: 700, height: 300)
        let size = OverlayPlacement.searchSize(windowFrame: window, visible: visible)
        let frame = OverlayPlacement.searchFrame(windowFrame: window, visible: visible, size: size)

        XCTAssertTrue(visible.contains(frame))
        XCTAssertEqual(frame.minX, window.midX - OverlayPlacement.searchWidth / 2)
        XCTAssertEqual(frame.minY, visible.minY, "the bottom edge is the part that gets clamped")
    }

    func testSearchFrameCentresOnTheScreenWithoutAWindow() {
        let size = OverlayPlacement.searchSize(windowFrame: nil, visible: visible)
        let frame = OverlayPlacement.searchFrame(windowFrame: nil, visible: visible, size: size)

        XCTAssertEqual(frame.midX, screenCentre.x)
        XCTAssertEqual(frame.midY, screenCentre.y)
    }

    func testSearchPaletteFillsTheHeightOfAFullscreenWindow() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = OverlayPlacement.searchSize(windowFrame: screen, visible: screen)
        let frame = OverlayPlacement.searchFrame(windowFrame: screen, visible: screen, size: size)

        XCTAssertEqual(size.width, OverlayPlacement.searchWidth)
        XCTAssertEqual(size.height, screen.height)
        XCTAssertEqual(frame.minY, screen.minY)
        XCTAssertEqual(frame.midY, screen.midY)
    }
}
