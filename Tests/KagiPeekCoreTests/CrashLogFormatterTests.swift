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
            callStack: ["0 KagiPeek 0x1 main + 1"]
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

    func testRenderedJSONIsReadableAndStable() throws {
        let report = CrashLogFormatter.makeReport(context: context())
        let text = CrashLogFormatter.render(report)
        XCTAssertTrue(text.contains("\"kind\" : \"nsexception\""))
        let decoded = try JSONDecoder().decode(CrashReport.self, from: Data(text.utf8))
        XCTAssertEqual(decoded, report)
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
