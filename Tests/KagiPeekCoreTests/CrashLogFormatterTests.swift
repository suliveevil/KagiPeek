import XCTest
@testable import KagiPeekCore

// 崩溃报告的形状是给「下一次启动」读的，也是给用户附在问题反馈里的，
// 因此字段与 fragment 的解析格式都要钉住。

final class CrashLogFormatterTests: XCTestCase {
    private func context(kind: String = "nsexception") -> CrashContext {
        CrashContext(
            kind: kind,
            exceptionName: "NSInternalInconsistencyException",
            exceptionReason: "boom",
            signalNumber: nil,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "2.3.0",
            appBuild: "42",
            macOSVersion: "Version 15.1 (Build 24B83)",
            modelIdentifier: "Mac14,2",
            isAppActive: true,
            recentActions: [
                ActionRecord(ts: 1_699_999_990, action: "panel.run", target: "com.apple.Safari")
            ],
            callStack: ["0 Kaname 0x1 main + 1"]
        )
    }

    func testReportCarriesTheWholeStory() {
        let report = CrashLogFormatter.makeReport(context: context())
        XCTAssertEqual(report.format, CrashReport.currentFormat)
        XCTAssertEqual(report.kind, "nsexception")
        XCTAssertEqual(report.exceptionName, "NSInternalInconsistencyException")
        XCTAssertEqual(report.exceptionReason, "boom")
        XCTAssertEqual(report.appVersion, "2.3.0")
        XCTAssertEqual(report.macOSVersion, "Version 15.1 (Build 24B83)")
        XCTAssertEqual(report.modelIdentifier, "Mac14,2")
        XCTAssertTrue(report.isAppActive)
        XCTAssertEqual(report.recentActions.count, 1)
        XCTAssertEqual(report.callStack?.count, 1)
    }

    func testSignalReportNamesTheSignal() {
        var signalContext = context(kind: "signal")
        signalContext.signalNumber = SIGSEGV
        let report = CrashLogFormatter.makeReport(context: signalContext)
        XCTAssertEqual(report.signalNumber, SIGSEGV)
        XCTAssertEqual(report.signalName, "SIGSEGV")
    }

    /// 空的 recentActions / logTail 有两种含义：这一段时间真的没有内容，或者读取失败了。
    /// 报告必须把第二种说出来，否则读者会把一次权限失败当成「崩溃前什么都没做」。
    func testPartialReportFailuresTravelWithTheReport() {
        var failingContext = context(kind: "signal")
        failingContext.recentActions = []
        failingContext.recentActionsError = "the action mirror could not be read: permission denied"
        let report = CrashLogFormatter.makeReport(
            context: failingContext,
            logTail: [],
            logTailError: "the file is not valid UTF-8"
        )
        XCTAssertEqual(report.recentActionsError, "the action mirror could not be read: permission denied")
        XCTAssertEqual(report.logTailError, "the file is not valid UTF-8")
    }

    func testHealthyPartialReportHasNoFailureFields() {
        let report = CrashLogFormatter.makeReport(context: context(), logTail: ["one line"])
        XCTAssertNil(report.recentActionsError)
        XCTAssertNil(report.logTailError)
    }

    func testRenderedJSONIsReadableAndStable() throws {
        let report = CrashLogFormatter.makeReport(context: context())
        let text = CrashLogFormatter.render(report)
        XCTAssertTrue(text.contains("\"kind\" : \"nsexception\""))
        let decoded = try JSONDecoder().decode(CrashReport.self, from: Data(text.utf8))
        XCTAssertEqual(decoded, report)
    }

    func testAnUnserialisableReportSaysSoInsteadOfLookingEmpty() throws {
        // 这条分支曾被注释称为「死路径」，兜底值是 {}。它不是死的：occurredAt 是 Double，
        // 而 JSONEncoder 对非有限浮点数的默认策略是 .throw —— 一个 NaN 时间就能触发。
        // {} 能解析、看起来完整、且什么都没说，读者会以为这次崩溃本来就没带信息。
        var broken = context()
        broken.occurredAt = Date(timeIntervalSince1970: .nan)
        let text = CrashLogFormatter.render(CrashLogFormatter.makeReport(context: broken))
        XCTAssertNotEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "{}")
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            "兜底值必须是能解析的 JSON 对象，而不是空对象"
        )
        let message = try XCTUnwrap(object["error"] as? String)
        XCTAssertTrue(message.contains("could not be serialised"), "got: \(message)")
    }

    func testLogTailCanBeAttachedLater() {
        let report = CrashLogFormatter.makeReport(context: context(), logTail: ["line one", "line two"])
        XCTAssertEqual(report.logTail, ["line one", "line two"])
    }

    func testPartialFragmentParsesBack() {
        let raw = """
            ver=2.3.0
            build=42
            os=Version 15.1 (Build 24B83)
            model=Mac14,2
            pid=777
            sig=11
            time=1700000000

            """
        let info = CrashLogFormatter.parsePartial(raw)
        XCTAssertEqual(info?.appVersion, "2.3.0")
        XCTAssertEqual(info?.appBuild, "42")
        XCTAssertEqual(info?.macOSVersion, "Version 15.1 (Build 24B83)")
        XCTAssertEqual(info?.modelIdentifier, "Mac14,2")
        XCTAssertEqual(info?.signalNumber, 11)
        XCTAssertEqual(info?.pid, 777)
        XCTAssertEqual(info?.timestamp, 1_700_000_000)
    }

    func testDamagedFragmentIsRefused() {
        XCTAssertNil(CrashLogFormatter.parsePartial("garbage"))
        XCTAssertNil(CrashLogFormatter.parsePartial("ver=1 os=x model=y pid=not-a-number sig=11 time=1"))
    }

    func testSignalNamesCoverEveryHandledSignal() {
        XCTAssertEqual(CrashLogFormatter.signalName(SIGABRT), "SIGABRT")
        XCTAssertEqual(CrashLogFormatter.signalName(SIGSEGV), "SIGSEGV")
        XCTAssertEqual(CrashLogFormatter.signalName(SIGBUS), "SIGBUS")
        XCTAssertEqual(CrashLogFormatter.signalName(SIGILL), "SIGILL")
        XCTAssertEqual(CrashLogFormatter.signalName(SIGFPE), "SIGFPE")
        XCTAssertEqual(CrashLogFormatter.signalName(SIGTRAP), "SIGTRAP")
    }
}
