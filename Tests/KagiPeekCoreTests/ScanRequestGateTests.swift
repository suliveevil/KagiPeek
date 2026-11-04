import XCTest
@testable import KagiPeekCore

/// 扫描请求的作废判定：只有最新一次请求的 token 还能发布结果。
///
/// 扫描比它服务的那次点击活得久——用户切了 App、又开了一次面板——旧扫描跑完时不能把
/// 过期的目录盖到当前界面上。发号是原子的，所以两个请求不可能都认为自己是「最新」。
final class ScanRequestGateTests: XCTestCase {
    func testEachRequestGetsANewerToken() {
        let gate = ScanRequestGate()
        let first = gate.begin()
        let second = gate.begin()
        XCTAssertGreaterThan(second, first)
    }

    func testOnlyTheNewestTokenIsCurrent() {
        let gate = ScanRequestGate()
        let first = gate.begin()
        XCTAssertTrue(gate.isCurrent(first))
        let second = gate.begin()
        XCTAssertTrue(gate.isCurrent(second))
        XCTAssertFalse(gate.isCurrent(first))
    }

    func testUnissuedTokenIsNeverCurrent() {
        let gate = ScanRequestGate()
        XCTAssertFalse(gate.isCurrent(0))
        _ = gate.begin()
        XCTAssertFalse(gate.isCurrent(0))
    }

    // MARK: - 槽位准入

    private let deadline = Date(timeIntervalSince1970: 1_000)

    func testCurrentRequestBeforeDeadlineMayScan() {
        XCTAssertEqual(
            ScanAdmission.decide(
                isCurrent: true,
                now: deadline.addingTimeInterval(-0.01),
                deadline: deadline
            ),
            .scan
        )
    }

    /// 已经被新请求取代：不拿槽，直接从缓存/内置目录作答。
    func testSupersededRequestAnswersWithoutTakingASlot() {
        XCTAssertEqual(
            ScanAdmission.decide(isCurrent: false, now: deadline.addingTimeInterval(-1), deadline: deadline),
            .answerNow
        )
    }

    /// 过了 deadline：扫描结果已经没人等，同样不拿槽。
    func testRequestPastItsDeadlineAnswersImmediately() {
        XCTAssertEqual(
            ScanAdmission.decide(isCurrent: true, now: deadline, deadline: deadline),
            .answerNow
        )
        XCTAssertEqual(
            ScanAdmission.decide(isCurrent: true, now: deadline.addingTimeInterval(0.2), deadline: deadline),
            .answerNow
        )
    }

    /// 槽位等待必须小于总 deadline，否则等到了也没有时间扫完。
    func testSlotWaitFitsInsideTheScanDeadline() {
        XCTAssertLessThan(ScanAdmission.slotWaitTimeout, 1.5)
        XCTAssertGreaterThan(ScanAdmission.slotWaitTimeout, 0)
    }

    /// 并发发号不能发出重复的 token，否则两次扫描会同时认为自己可以发布。
    func testConcurrentRequestsGetDistinctTokens() {
        let gate = ScanRequestGate()
        var tokens: [UInt64] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            let token = gate.begin()
            lock.lock()
            tokens.append(token)
            lock.unlock()
        }
        XCTAssertEqual(Set(tokens).count, tokens.count)
        XCTAssertEqual(gate.begin(), (tokens.max() ?? 0) + 1)
    }
}
