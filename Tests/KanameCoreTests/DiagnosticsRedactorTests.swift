import XCTest
@testable import KanameCore

// 报告的脱敏是一次递归遍历：路径名是它唯一的输出证据，所以这里钉住「路径怎么拼」，
// 而不是重复 `Sanitizer` 自己的规则测试。

final class DiagnosticsRedactorTests: XCTestCase {
    func testNestedFieldsCarryTheirPath() {
        let outcome = DiagnosticsRedactor.redact([
            "settings": ["ignoredCommands": ["contact alice@example.com"]] as [String: Any],
            "prefix": "token=abc123"
        ])
        XCTAssertEqual(outcome.redactedFields, ["prefix", "settings.ignoredCommands"])

        let settings = outcome.payload["settings"] as? [String: Any]
        XCTAssertEqual(settings?["ignoredCommands"] as? [String], ["contact <email>"])
        XCTAssertEqual(outcome.payload["prefix"] as? String, "token=<redacted>")
    }

    /// 说清是哪个字段被剪就够了；具体第几个元素不改变读者要做的事。
    func testArraysReportTheFieldNotTheIndex() {
        let outcome = DiagnosticsRedactor.redact([
            "windowTitles": ["Kaname", "a@b.com", "another@b.com"]
        ])
        XCTAssertEqual(outcome.redactedFields, ["windowTitles"])
        XCTAssertEqual(
            outcome.payload["windowTitles"] as? [String],
            ["Kaname", "<email>", "<email>"]
        )
    }

    func testNumbersAndBooleansAreLeftAlone() {
        let outcome = DiagnosticsRedactor.redact([
            "count": 3,
            "enabled": true,
            "nothing": NSNull()
        ])
        XCTAssertEqual(outcome.payload["count"] as? Int, 3)
        XCTAssertEqual(outcome.payload["enabled"] as? Bool, true)
        XCTAssertTrue(outcome.payload["nothing"] is NSNull)
        XCTAssertTrue(outcome.redactedFields.isEmpty)
    }

    func testAHomePrefixIsShortenedButNotReported() {
        let outcome = DiagnosticsRedactor.redact(
            ["dataFolder": "/Users/alice/Library/Kaname"],
            homePrefix: "/Users/alice"
        )
        XCTAssertEqual(outcome.payload["dataFolder"] as? String, "~/Library/Kaname")
        XCTAssertTrue(outcome.redactedFields.isEmpty)
    }
}
