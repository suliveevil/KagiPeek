import XCTest
@testable import KagiPeekCore

// 忽略命令从「一份全局标题清单」升级为「可按 App 收窄的规则」。
// 这两件事最容易出错：scope 的默认含义，以及旧设置能不能无损搬过来。

final class IgnoredCommandsTests: XCTestCase {
    private func rule(_ title: String, _ bundleID: String? = nil) -> IgnoredCommand {
        IgnoredCommand(title: title, appBundleID: bundleID)
    }

    // MARK: - 匹配

    func testGlobalRuleMatchesEveryApp() {
        let rules = [rule("Minimize")]
        XCTAssertTrue(IgnoredCommands.isIgnored("Minimize", bundleID: "com.apple.Safari", in: rules))
        XCTAssertTrue(IgnoredCommands.isIgnored("Minimize", bundleID: nil, in: rules))
    }

    func testScopedRuleMatchesOnlyItsApp() {
        let rules = [rule("Reload Page", "com.apple.Safari")]
        XCTAssertTrue(IgnoredCommands.isIgnored("Reload Page", bundleID: "com.apple.Safari", in: rules))
        XCTAssertFalse(IgnoredCommands.isIgnored("Reload Page", bundleID: "com.apple.dt.Xcode", in: rules))
        // 内置目录与系统热键没有 bundle id：定向规则不该误伤它们。
        XCTAssertFalse(IgnoredCommands.isIgnored("Reload Page", bundleID: nil, in: rules))
    }

    func testMatchingIgnoresCase() {
        let rules = [rule("reload page", "com.apple.Safari")]
        XCTAssertTrue(IgnoredCommands.isIgnored("Reload Page", bundleID: "com.apple.Safari", in: rules))
    }

    func testEmptyRulesNeverMatch() {
        XCTAssertFalse(IgnoredCommands.isIgnored("Minimize", bundleID: nil, in: []))
    }

    func testDifferentTitleIsNotIgnored() {
        let rules = [rule("Minimize")]
        XCTAssertFalse(IgnoredCommands.isIgnored("Minimise", bundleID: nil, in: rules))
    }

    // MARK: - 归一化

    func testNormalizeTrimsDropsEmptyAndDeduplicates() {
        let rules = [
            rule("  Minimize "),
            rule("Minimize"),
            rule("   "),
            rule("Reload Page", " com.apple.Safari ")
        ]
        let normalized = IgnoredCommands.normalized(rules)
        XCTAssertEqual(normalized.count, 2)
        XCTAssertTrue(normalized.contains(rule("Minimize")))
        XCTAssertTrue(normalized.contains(rule("Reload Page", "com.apple.Safari")))
    }

    func testSameTitleInTwoAppsIsTwoRules() {
        let normalized = IgnoredCommands.normalized([
            rule("Reload Page", "com.apple.Safari"),
            rule("Reload Page", "com.apple.dt.Xcode")
        ])
        XCTAssertEqual(normalized.count, 2)
    }

    func testScopesListGlobalFirst() {
        let scopes = IgnoredCommands.scopes(in: [
            rule("Reload Page", "com.apple.dt.Xcode"),
            rule("Minimize")
        ])
        XCTAssertEqual(scopes, [nil, "com.apple.dt.Xcode"])
    }

    func testScopesSkipEmpty() {
        XCTAssertTrue(IgnoredCommands.scopes(in: []).isEmpty)
    }

    // MARK: - 旧设置迁移

    func testLegacyTitleListBecomesGlobalRules() throws {
        let legacy = """
        {"schemaVersion":3,"settings":{"ignoredCommandTitles":["Minimize","Center"]}}
        """
        let payload = try JSONDecoder().decode(SettingsPayload.self, from: Data(legacy.utf8))
        let rules = payload.settings.ignoredCommands
        XCTAssertEqual(rules.count, 2)
        XCTAssertTrue(rules.allSatisfy { $0.appBundleID == nil })
        XCTAssertEqual(Set(rules.map(\.title)), ["Minimize", "Center"])
    }

    func testNewRulesRoundTrip() throws {
        var settings = AppSettingsSnapshot()
        settings.ignoredCommands = [
            rule("Minimize"),
            rule("Reload Page", "com.apple.Safari")
        ]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettingsSnapshot.self, from: data)
        XCTAssertEqual(decoded.ignoredCommands, settings.ignoredCommands)
    }

    func testMissingKeyFallsBackToEmpty() throws {
        let payload = try JSONDecoder().decode(
            SettingsPayload.self,
            from: Data(#"{"schemaVersion":3,"settings":{}}"#.utf8)
        )
        XCTAssertTrue(payload.settings.ignoredCommands.isEmpty)
    }
}
