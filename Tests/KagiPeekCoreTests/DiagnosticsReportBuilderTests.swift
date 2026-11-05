import XCTest
@testable import KagiPeekCore

// 这份报告过去只能靠 `KAGIPEEK_SELFTEST=1` 端到端验证：装配逻辑在引擎里，而引擎没有测试网，
// 也无法在测试里构造。搬到 `DiagnosticsReportBuilder` 之后它只需要一个 `Input`，于是字段映射
// 可以在这里钉住——端到端那条路径仍然保留，但它验证的是「装得出来」，这里验证的是「装得对」。

final class DiagnosticsReportBuilderTests: XCTestCase {
    private func input(
        generatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        scanState: ScanState = .ok,
        crashRecoveryErrors: [String] = [],
        actionMirrorError: String? = nil,
        logLinesDropped: Int = 0
    ) -> DiagnosticsReportBuilder.Input {
        DiagnosticsReportBuilder.Input(
            generatedAt: generatedAt,
            settings: AppSettingsSnapshot(),
            hasAccessibility: true,
            hasInputMonitoring: false,
            isListening: true,
            catalogSize: 57,
            frontmostName: "Safari",
            frontmostBundleID: "com.apple.Safari",
            usedBuiltInCatalog: false,
            panelSelectionIndex: 3,
            panelRowCount: 24,
            prefixText: "⌘C",
            scanDuration: 0.012,
            scanState: scanState,
            conflictCount: 2,
            systemBindingCount: 79,
            usageTracked: 41,
            usageTotalPresses: 512,
            favoriteCount: 6,
            dataFolderPath: "/tmp/kagipeek",
            windowTitles: ["KagiPeek", "KagiPeek Settings"],
            crashRecoveryErrors: crashRecoveryErrors,
            actionMirrorError: actionMirrorError,
            logLinesDropped: logLinesDropped
        )
    }

    private func object(from input: DiagnosticsReportBuilder.Input) throws -> [String: Any] {
        let data = try DiagnosticsReportBuilder.report(input)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTheReportCarriesWhatItWasGiven() throws {
        let payload = try object(from: input())
        XCTAssertEqual(payload["hasAccessibility"] as? Bool, true)
        XCTAssertEqual(payload["hasInputMonitoring"] as? Bool, false)
        XCTAssertEqual(payload["catalogSize"] as? Int, 57)
        XCTAssertEqual(payload["frontmost"] as? String, "Safari")
        XCTAssertEqual(payload["frontmostBundleID"] as? String, "com.apple.Safari")
        XCTAssertEqual(payload["panelSelectionIndex"] as? Int, 3)
        XCTAssertEqual(payload["panelRowCount"] as? Int, 24)
        XCTAssertEqual(payload["prefix"] as? String, "⌘C")
        XCTAssertEqual(payload["conflicts"] as? Int, 2)
        XCTAssertEqual(payload["systemHotkeys"] as? Int, 79)
        XCTAssertEqual(payload["usageTracked"] as? Int, 41)
        XCTAssertEqual(payload["usageTotalPresses"] as? Int, 512)
        XCTAssertEqual(payload["favorites"] as? Int, 6)
        XCTAssertEqual(payload["dataFolder"] as? String, "/tmp/kagipeek")
        XCTAssertEqual(payload["windowTitles"] as? [String], ["KagiPeek", "KagiPeek Settings"])
    }

    /// 时间由调用方传入而不是内部读 `Date()`，所以输出是确定的——这是能测的前提。
    func testTheTimestampIsPinnedByTheCaller() throws {
        let moment = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = try object(from: input(generatedAt: moment))
        XCTAssertEqual(payload["generatedAt"] as? String, ISO8601DateFormatter().string(from: moment))
    }

    func testEveryScanStateHasAName() throws {
        XCTAssertEqual(try object(from: input(scanState: .ok))["scanState"] as? String, "ok")
        XCTAssertEqual(try object(from: input(scanState: .noMenus))["scanState"] as? String, "noMenus")
        XCTAssertEqual(
            try object(from: input(scanState: .permissionDenied))["scanState"] as? String,
            "permissionDenied"
        )
    }

    /// 脱敏规则失效是这份报告里唯一「离机会活下来」的失败，所以它必须在场且为空。
    /// 真正让它为空的是 `SanitizerRuleCompilationTests`；这里钉住的是「它确实被带上了」。
    func testRedactionStatusIsAlwaysCarried() throws {
        let payload = try object(from: input())
        XCTAssertEqual(payload["sanitizerFailedPatterns"] as? [String], [])
    }

    func testTheSettingsSnapshotIsFoldedIn() throws {
        let payload = try object(from: input())
        XCTAssertNotNil(payload["settings"], "settings 是一段增益，正常路径下必须在")
        XCTAssertNil(payload["settingsError"], "正常路径下不该有 settingsError")
    }

    func testTheLogCommandQuotesTheRealBundleID() throws {
        let payload = try object(from: input())
        let command = try XCTUnwrap(payload["logCommand"] as? String)
        XCTAssertTrue(command.contains("subsystem == \"" + (Bundle.main.bundleIdentifier ?? "?") + "\""), command)
    }

    /// 部分成功必须把理由写进产物：读不到的崩溃片段、写不出的动作镜像、被丢弃的日志行，
    /// 三者都是「报告看起来正常但内容有洞」的来源。
    func testPartialFailuresAreWrittenIntoTheReport() throws {
        let payload = try object(from: input(
            crashRecoveryErrors: ["kagipeek-crash-1-signal.partial could not be read and was kept: permission denied"],
            actionMirrorError: "the recent-action mirror could not be written: disk full",
            logLinesDropped: 7
        ))
        XCTAssertEqual(
            payload["crashRecoveryErrors"] as? [String],
            ["kagipeek-crash-1-signal.partial could not be read and was kept: permission denied"]
        )
        XCTAssertEqual(payload["actionMirrorError"] as? String, "the recent-action mirror could not be written: disk full")
        XCTAssertEqual(payload["logLinesDropped"] as? Int, 7)
    }

    /// 一切正常时这些字段缺席，而不是带着空值出现在报告里——与 `settingsError` 的约定一致。
    func testPartialFailureFieldsAreAbsentWhenNothingFailed() throws {
        let payload = try object(from: input())
        XCTAssertNil(payload["crashRecoveryErrors"])
        XCTAssertNil(payload["actionMirrorError"])
        XCTAssertNil(payload["logLinesDropped"])
    }
}
