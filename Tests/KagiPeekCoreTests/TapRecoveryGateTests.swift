import XCTest
@testable import KagiPeekCore

/// 恢复闸门：一次已排队的重新启用会挡住重复通知，而一旦那次恢复没有成功执行，
/// 闸门必须重新打开，否则后续禁用通知永远被丢弃、只能重启 App。
final class TapRecoveryGateTests: XCTestCase {
    func testStoppedMonitorDoesNotStartRecovery() {
        let gate = TapRecoveryGate()
        XCTAssertFalse(gate.shouldHandleDisable(isRunning: false))
    }

    func testIdleRunningMonitorHandlesTheDisable() {
        let gate = TapRecoveryGate()
        XCTAssertTrue(gate.shouldHandleDisable(isRunning: true))
    }

    func testQueuedRecoveryDropsDuplicateDisables() {
        var gate = TapRecoveryGate()
        gate.schedule()
        XCTAssertFalse(gate.shouldHandleDisable(isRunning: true))
        XCTAssertFalse(gate.shouldHandleDisable(isRunning: false))
    }

    /// 工作项真正跑完之后：下一次禁用可以再试。
    func testFinishedRecoveryReopensTheGate() {
        var gate = TapRecoveryGate()
        gate.schedule()
        gate.finish()
        XCTAssertTrue(gate.shouldHandleDisable(isRunning: true))
    }

    /// 工作项被取消、或从未被 run loop 调度：闸门同样要打开。
    func testCancelledOrUnscheduledRecoveryReopensTheGate() {
        var gate = TapRecoveryGate()
        gate.schedule()
        gate.finish()
        XCTAssertTrue(gate.shouldHandleDisable(isRunning: true))
    }
}
