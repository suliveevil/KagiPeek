import CoreGraphics
import XCTest
@testable import KagiPeekCore

/// A space or display change moves the windows the panel anchored to, so the cached frames
/// must be thrown away rather than reused. These assertions pin the cache's only job: never
/// let a frame outlive the pid (or the space) it was read for.
final class PanelAnchorCacheTests: XCTestCase {
    private let window = CGRect(x: 100, y: 100, width: 600, height: 400)
    private let element = CGRect(x: 200, y: 150, width: 100, height: 20)

    func testInvalidateClearsThePidAndBothFrames() {
        var cache = PanelAnchorCache()
        _ = cache.beginRead(pid: 42)
        _ = cache.apply(pid: 42, windowFrame: window, focusedElementFrame: element)
        XCTAssertEqual(cache.pid, 42)
        XCTAssertNotNil(cache.windowFrame)

        cache.invalidate()
        XCTAssertEqual(cache.pid, 0)
        XCTAssertNil(cache.windowFrame)
        XCTAssertNil(cache.focusedElementFrame)
    }

    func testBeginReadIsTrueFirstTimeAndFalseOnceTheFrameIsKnown() {
        var cache = PanelAnchorCache()
        XCTAssertTrue(cache.beginRead(pid: 42))
        XCTAssertEqual(cache.pid, 42)
        XCTAssertTrue(cache.apply(pid: 42, windowFrame: window, focusedElementFrame: element))
        XCTAssertFalse(cache.beginRead(pid: 42))
        XCTAssertEqual(cache.windowFrame, window)
    }

    func testBeginReadForANewPidDropsTheOldFrames() {
        var cache = PanelAnchorCache()
        _ = cache.beginRead(pid: 42)
        _ = cache.apply(pid: 42, windowFrame: window, focusedElementFrame: element)
        XCTAssertTrue(cache.beginRead(pid: 43))
        XCTAssertEqual(cache.pid, 43)
        XCTAssertNil(cache.windowFrame)
        XCTAssertNil(cache.focusedElementFrame)
    }

    func testApplyFromAStalePidIsIgnored() {
        var cache = PanelAnchorCache()
        _ = cache.beginRead(pid: 42)
        _ = cache.apply(pid: 42, windowFrame: window, focusedElementFrame: element)

        let other = CGRect(x: 0, y: 0, width: 300, height: 200)
        XCTAssertFalse(cache.apply(pid: 43, windowFrame: other, focusedElementFrame: nil))
        XCTAssertEqual(cache.pid, 42)
        XCTAssertEqual(cache.windowFrame, window)
        XCTAssertEqual(cache.focusedElementFrame, element)
    }

    /// The first frame after an app switch has no window to cover; returning the whole
    /// visible area keeps a tall window covered until the real frame arrives.
    func testCoverSizeWithoutAWindowFrameUsesTheVisibleFrame() {
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let natural = CGSize(width: 680, height: 460)
        XCTAssertEqual(
            OverlayPlacement.coverSize(windowFrame: nil, visible: visible, natural: natural),
            visible.size
        )
    }
}
