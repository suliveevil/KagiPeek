import XCTest
@testable import KanameCore

// 哨兵文件的判定是「崩溃 / 强退 / 正常退出」三者的分界线：
// 只有它残留，才说明上一个进程没来得及告别。
// 但「残留」还要问一句它属于谁——第二个实例启动时会看到**仍在运行**那个进程的哨兵。

final class SentinelStateTests: XCTestCase {
    private let me: Int32 = 4242

    private func launch(
        sentinelExists: Bool = true,
        ownerPID: Int32? = nil,
        ownerIsLive: Bool = false,
        crashPartialExists: Bool = false
    ) -> SentinelState {
        SentinelState.launchDecision(
            sentinelExists: sentinelExists,
            ownerPID: ownerPID,
            ownerIsLive: ownerIsLive,
            currentPID: me,
            crashPartialExists: crashPartialExists
        )
    }

    func testNoSentinelMeansCleanLaunch() {
        XCTAssertEqual(launch(sentinelExists: false), .clean)
    }

    func testLeftoverSentinelWithFragmentIsACrash() {
        XCTAssertEqual(
            launch(ownerPID: 1, crashPartialExists: true),
            .reportUnexpectedExit(partial: true)
        )
    }

    func testLeftoverSentinelWithoutFragmentIsAnUnexpectedExit() {
        XCTAssertEqual(
            launch(ownerPID: 1, crashPartialExists: false),
            .reportUnexpectedExit(partial: false)
        )
    }

    /// 双击启动、`open -a` 另一个副本、按安装包跑诊断——都会看到活着的那个实例的哨兵。
    func testSentinelOfAStillRunningInstanceIsNotACrash() {
        XCTAssertEqual(
            launch(ownerPID: 1, ownerIsLive: true, crashPartialExists: false),
            .ownedByLiveProcess(pid: 1)
        )
    }

    /// 哨兵写着我们自己的 pid：上一个会话不可能还是我们，所以那是被回收的 pid，owner 已死。
    func testSentinelNamingOurOwnPIDIsADeadOwner() {
        XCTAssertEqual(
            launch(ownerPID: me, ownerIsLive: true),
            .reportUnexpectedExit(partial: false)
        )
    }

    /// 旧格式（没有 pid 字段）或人工编辑过的文件：回到只看「文件在不在」的判定。
    func testSentinelWithoutAPIDKeepsTheOldVerdict() {
        XCTAssertEqual(
            launch(ownerPID: nil, ownerIsLive: false),
            .reportUnexpectedExit(partial: false)
        )
    }

    func testOwnerPIDParsesTheWrittenFormat() {
        XCTAssertEqual(SentinelState.ownerPID(in: "pid=1234 started=2026-11-07T03:16:01Z\n"), 1234)
    }

    func testOwnerPIDHandlesFieldOrderAndLineEndings() {
        XCTAssertEqual(SentinelState.ownerPID(in: "started=2026-11-07T03:16:01Z pid=99"), 99)
        XCTAssertEqual(SentinelState.ownerPID(in: "pid=7\r\nstarted=x\r\n"), 7)
    }

    func testOwnerPIDRejectsContentWithoutIt() {
        XCTAssertNil(SentinelState.ownerPID(in: ""))
        XCTAssertNil(SentinelState.ownerPID(in: "started=2026-11-07T03:16:01Z\n"))
        XCTAssertNil(SentinelState.ownerPID(in: "pid=\n"))
        XCTAssertNil(SentinelState.ownerPID(in: "pid=notanumber\n"))
    }

    func testCleanTerminateRemovesTheSentinelItWrote() {
        XCTAssertEqual(
            SentinelState.terminateDecision(sentinelExists: true, ownedByThisProcess: true),
            .remove
        )
    }

    /// 第二个实例走过同一条退出路径，但它没写过哨兵——删掉它等于抹掉活着的那个实例的崩溃检测。
    func testTerminateLeavesASentinelItDidNotWrite() {
        XCTAssertEqual(
            SentinelState.terminateDecision(sentinelExists: true, ownedByThisProcess: false),
            .leaveAlone
        )
    }

    func testTerminateWithoutSentinelIsANoOp() {
        XCTAssertEqual(
            SentinelState.terminateDecision(sentinelExists: false, ownedByThisProcess: false),
            .clean
        )
        XCTAssertEqual(
            SentinelState.terminateDecision(sentinelExists: false, ownedByThisProcess: true),
            .clean
        )
    }
}
