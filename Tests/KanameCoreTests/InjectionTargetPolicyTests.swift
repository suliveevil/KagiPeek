import XCTest
@testable import KanameCore

/// 注入前的目标判定：只有「目标进程就是前台且真的活跃」才允许投递按键。
///
/// 这条判定存在的理由很具体：面板和搜索面板都会暂时拿走键盘，回放前如果目标没有回到
/// 前台，按键就会落进别的窗口，做出不可预料的事，看起来还像命令执行了。
final class InjectionTargetPolicyTests: XCTestCase {
    private let target = InjectionTarget(processID: 42, bundleID: "com.example.app")

    func testMatchingActiveTargetIsAllowedToSend() {
        XCTAssertEqual(
            InjectionTargetPolicy.verdict(
                target: target,
                frontmostBundleID: "com.example.app",
                frontmostPID: 42,
                isActive: true
            ),
            .send
        )
    }

    func testInactiveTargetIsRefusedEvenWhenItIsFrontmostByPid() {
        XCTAssertEqual(
            InjectionTargetPolicy.verdict(
                target: target,
                frontmostBundleID: "com.example.app",
                frontmostPID: 42,
                isActive: false
            ),
            .notActive
        )
    }

    func testNoFrontmostApplicationIsRefused() {
        XCTAssertEqual(
            InjectionTargetPolicy.verdict(
                target: target,
                frontmostBundleID: nil,
                frontmostPID: nil,
                isActive: true
            ),
            .noFrontmostApp
        )
    }

    /// 重启后的同一个 App 是另一个进程；pid 不同就不算同一个目标。
    func testDifferentProcessIsRefused() {
        XCTAssertEqual(
            InjectionTargetPolicy.verdict(
                target: target,
                frontmostBundleID: "com.example.app",
                frontmostPID: 43,
                isActive: true
            ),
            .wrongApp
        )
    }

    func testBundleMismatchOnTheSameProcessIsRefused() {
        XCTAssertFalse(
            InjectionTargetPolicy.matches(
                target: target,
                frontmostBundleID: "com.example.other",
                frontmostPID: 42
            )
        )
    }

    /// 任何一侧不知道 bundle id 时，进程号是唯一可用的证据。
    func testPidDecidesWhenBundleIsUnknown() {
        XCTAssertTrue(
            InjectionTargetPolicy.matches(
                target: InjectionTarget(processID: 42, bundleID: nil),
                frontmostBundleID: "com.example.app",
                frontmostPID: 42
            )
        )
        XCTAssertTrue(
            InjectionTargetPolicy.matches(
                target: target,
                frontmostBundleID: nil,
                frontmostPID: 42
            )
        )
    }

    // MARK: - 延迟前后两次校验

    private func snapshot(
        pid: Int32? = 42,
        bundle: String? = "com.example.app",
        isActive: Bool = true
    ) -> FrontmostState {
        FrontmostState(bundleID: bundle, processID: pid, isActive: isActive)
    }

    func testVerdictReadsTheCapturedSnapshotInsteadOfTheLiveWorld() {
        XCTAssertEqual(
            InjectionTimeline.verdict(target: target, frontmost: snapshot()),
            .send
        )
        XCTAssertEqual(
            InjectionTimeline.verdict(target: target, frontmost: snapshot(pid: 43)),
            .wrongApp
        )
        XCTAssertEqual(
            InjectionTimeline.verdict(target: target, frontmost: snapshot(isActive: false)),
            .notActive
        )
    }

    /// 延迟前后都是同一个目标：允许投递。
    func testUnchangedTargetAcrossTheDelayIsSent() {
        XCTAssertNil(
            InjectionTimeline.outcome(beforeDelay: .send, afterDelay: .send)
        )
    }

    /// 延迟期间目标被别的 App 顶掉：一个键都不能发。
    func testTargetChangingDuringTheDelayWithholdsTheWholeChord() {
        XCTAssertEqual(
            InjectionTimeline.outcome(beforeDelay: .send, afterDelay: .wrongApp),
            .targetNotFrontmost
        )
    }

    /// 激活阶段就没站到前台：不等延迟，直接不发。
    func testWrongTargetBeforeTheDelayWithholdsWithoutWaiting() {
        XCTAssertEqual(
            InjectionTimeline.outcome(beforeDelay: .wrongApp, afterDelay: .send),
            .targetNotFrontmost
        )
    }

    /// 延迟期间目标进程失活（例如被系统挂起）：同样不发。
    func testTargetGoingInactiveDuringTheDelayWithholds() {
        XCTAssertEqual(
            InjectionTimeline.outcome(beforeDelay: .send, afterDelay: .notActive),
            .targetNotFrontmost
        )
    }
}
