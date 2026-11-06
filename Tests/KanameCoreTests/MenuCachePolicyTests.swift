import XCTest
@testable import KanameCore

/// 菜单扫描磁盘缓存的纯规则：什么算"仍然可信"（Menu-Bar-Search 的控制文件 + 我们的年龄上限）。
final class MenuCachePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let fingerprint = MenuCachePolicy.fingerprint(showAppleMenu: false)

    func testFingerprintTracksScanShapingSettings() {
        XCTAssertNotEqual(
            MenuCachePolicy.fingerprint(showAppleMenu: false),
            MenuCachePolicy.fingerprint(showAppleMenu: true)
        )
    }

    func testControlIsOnlyCurrentForAMatchingFingerprint() {
        XCTAssertTrue(MenuCachePolicy.isControlCurrent(fingerprint, fingerprint: fingerprint))
        XCTAssertFalse(MenuCachePolicy.isControlCurrent(nil, fingerprint: fingerprint))
        XCTAssertFalse(MenuCachePolicy.isControlCurrent("schema=1;appleMenu=1", fingerprint: fingerprint))
    }

    func testFreshEntryIsUsable() {
        XCTAssertTrue(MenuCachePolicy.isEntryUsable(
            scannedAt: now.addingTimeInterval(-60),
            entryFingerprint: fingerprint,
            fingerprint: fingerprint,
            now: now
        ))
    }

    func testEntryExpiresAtTheAgeCap() {
        // 窗口内可用，压线即失效：菜单会在 App 运行期间变化，缓存必须自我刷新。
        XCTAssertTrue(MenuCachePolicy.isEntryUsable(
            scannedAt: now.addingTimeInterval(-(MenuCachePolicy.entryMaxAge - 1)),
            entryFingerprint: fingerprint,
            fingerprint: fingerprint,
            now: now
        ))
        XCTAssertFalse(MenuCachePolicy.isEntryUsable(
            scannedAt: now.addingTimeInterval(-MenuCachePolicy.entryMaxAge),
            entryFingerprint: fingerprint,
            fingerprint: fingerprint,
            now: now
        ))
    }

    func testEntryFromOtherSettingsIsNotUsable() {
        XCTAssertFalse(MenuCachePolicy.isEntryUsable(
            scannedAt: now,
            entryFingerprint: MenuCachePolicy.fingerprint(showAppleMenu: true),
            fingerprint: fingerprint,
            now: now
        ))
    }

    /// 时钟回跳不能把一份过期扫描永久救活。
    func testFutureTimestampIsNotUsable() {
        XCTAssertFalse(MenuCachePolicy.isEntryUsable(
            scannedAt: now.addingTimeInterval(600),
            entryFingerprint: fingerprint,
            fingerprint: fingerprint,
            now: now
        ))
    }
}
