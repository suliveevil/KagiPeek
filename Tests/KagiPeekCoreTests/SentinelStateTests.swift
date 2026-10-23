import XCTest
@testable import KagiPeekCore

// 哨兵文件的判定是「崩溃 / 强退 / 正常退出」三者的分界线：
// 只有它残留，才说明上一个进程没来得及告别。

final class SentinelStateTests: XCTestCase {
    func testNoSentinelMeansCleanLaunch() {
        XCTAssertEqual(
            SentinelState.launchDecision(sentinelExists: false, crashPartialExists: false),
            .clean
        )
    }

    func testLeftoverSentinelWithFragmentIsACrash() {
        XCTAssertEqual(
            SentinelState.launchDecision(sentinelExists: true, crashPartialExists: true),
            .reportUnexpectedExit(partial: true)
        )
    }

    func testLeftoverSentinelWithoutFragmentIsAnUnexpectedExit() {
        XCTAssertEqual(
            SentinelState.launchDecision(sentinelExists: true, crashPartialExists: false),
            .reportUnexpectedExit(partial: false)
        )
    }

    func testCleanTerminateRemovesTheSentinel() {
        XCTAssertEqual(SentinelState.terminateDecision(sentinelExists: true), .remove)
    }

    func testTerminateWithoutSentinelIsANoOp() {
        XCTAssertEqual(SentinelState.terminateDecision(sentinelExists: false), .clean)
    }
}
