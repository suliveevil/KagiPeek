import XCTest
@testable import KagiPeekCore

// 这份报告过去只能靠 `KANAME_SELFTEST=1` 端到端验证：装配逻辑在引擎里，而引擎没有测试网，
// 也无法在测试里构造。搬到 `DiagnosticsReportBuilder` 之后它只需要一个 `Input`，于是字段映射
// 可以在这里钉住——端到端那条路径仍然保留，但它验证的是「装得出来」，这里验证的是「装得对」。

final class DiagnosticsReportBuilderTests: XCTestCase {
    private func input(
        generatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        settings: AppSettingsSnapshot = AppSettingsSnapshot(),
        dataFolderPath: String = "/tmp/kagipeek",
        windowTitles: [String] = ["Kaname", "Kaname Settings"],
        scanState: ScanState = .ok,
        crashRecoveryErrors: [String] = [],
        actionMirrorError: String? = nil,
        logLinesDropped: Int = 0,
        homePrefix: String? = nil
    ) -> DiagnosticsReportBuilder.Input {
        DiagnosticsReportBuilder.Input(
            generatedAt: generatedAt,
            settings: settings,
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
            dataFolderPath: dataFolderPath,
            windowTitles: windowTitles,
            crashRecoveryErrors: crashRecoveryErrors,
            actionMirrorError: actionMirrorError,
            logLinesDropped: logLinesDropped,
            homePrefix: homePrefix
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
        XCTAssertEqual(payload["windowTitles"] as? [String], ["Kaname", "Kaname Settings"])
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
            crashRecoveryErrors: ["kaname-crash-1-signal.partial could not be read and was kept: permission denied"],
            actionMirrorError: "the recent-action mirror could not be written: disk full",
            logLinesDropped: 7
        ))
        XCTAssertEqual(
            payload["crashRecoveryErrors"] as? [String],
            ["kaname-crash-1-signal.partial could not be read and was kept: permission denied"]
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

    // MARK: - 脱敏

    /// 窗口标题是别的 App 的内容：它可以是一份文档名、一个账号、一个文件夹。
    /// 报告是要给人的，所以它必须在写文件之前过一遍规则，而不是「反正只有标题」。
    func testWindowTitlesAreRedactedBeforeTheyReachTheFile() throws {
        let payload = try object(from: input(
            windowTitles: ["Kaname", "Invoice for alice@example.com"]
        ))
        XCTAssertEqual(
            payload["windowTitles"] as? [String],
            ["Kaname", "Invoice for <email>"]
        )
        XCTAssertEqual(payload["redactedFields"] as? [String], ["windowTitles"])
    }

    /// 整份 `settings` 里唯一由用户手输的就是 `ignoredCommands`，它过去原样进报告。
    func testTheSettingsBlobIsRedactedIncludingIgnoredCommands() throws {
        var settings = AppSettingsSnapshot()
        settings.ignoredCommands = [
            IgnoredCommand(title: "Share with alice@example.com", appBundleID: nil)
        ]
        let payload = try object(from: input(settings: settings))
        let settingsObject = try XCTUnwrap(payload["settings"] as? [String: Any])
        let commands = try XCTUnwrap(settingsObject["ignoredCommands"] as? [[String: Any]])
        XCTAssertEqual(commands.first?["title"] as? String, "Share with <email>")
        XCTAssertEqual(
            payload["redactedFields"] as? [String],
            ["settings.ignoredCommands.title"],
            "路径要指到具体字段，否则读报告的人不知道哪一段被剪过"
        )
    }

    /// 主目录换成 `~` 是每一份报告都会发生的事，所以它不算「剪裁」；
    /// 否则 `redactedFields` 永远非空，真正被剪的字段就淹没在里面。
    func testTheHomeDirectoryBecomesATildeWithoutBeingAnnouncedAsARedaction() throws {
        let payload = try object(from: input(
            dataFolderPath: "/Users/alice/Library/Application Support/Kaname",
            homePrefix: "/Users/alice"
        ))
        XCTAssertEqual(payload["dataFolder"] as? String, "~/Library/Application Support/Kaname")
        XCTAssertNil(payload["redactedFields"])
    }

    func testRedactionIsAnnouncedOnlyWhenItHappened() throws {
        let payload = try object(from: input())
        XCTAssertNil(payload["redactedFields"], "没剪过就不该出现这个字段")
    }
}
