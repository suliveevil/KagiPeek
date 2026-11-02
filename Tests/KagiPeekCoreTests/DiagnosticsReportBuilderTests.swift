import XCTest
@testable import KagiPeekCore

// 这份报告过去只能靠 `KAGIPEEK_SELFTEST=1` 端到端验证：装配逻辑在引擎里，而引擎没有测试网，
// 也无法在测试里构造。搬到 `DiagnosticsReportBuilder` 之后它只需要一个 `Input`，于是字段映射
// 可以在这里钉住——端到端那条路径仍然保留，但它验证的是「装得出来」，这里验证的是「装得对」。

final class DiagnosticsReportBuilderTests: XCTestCase {
    private func input(
        generatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        scanState: ScanState = .ok
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
            windowTitles: ["KagiPeek", "KagiPeek Settings"]
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
}
