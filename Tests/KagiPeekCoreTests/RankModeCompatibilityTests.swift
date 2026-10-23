import XCTest
@testable import KagiPeekCore

// 两个模式被删掉了：`contextFirst`（和 `frequencyDesc` 得分完全相同，改了没反应的选项）
// 和 `review`（按"最久未用"排，整个复习概念已移除）。
// 但已经存在的 settings.json 里可能还写着它们——解码必须软着陆，
// 因为这里一旦抛错，整份设置文件会被 JsonFileStore 当成损坏文件挪走。

final class RankModeCompatibilityTests: XCTestCase {
    func testRemovedContextFirstDecodesToFrequency() throws {
        let mode = try JSONDecoder().decode(RankMode.self, from: Data(#""contextFirst""#.utf8))
        XCTAssertEqual(mode, .frequencyDesc)
    }

    /// `review` 没有后继模式：它的排序方向和统计页的用途相反，所以退回默认值。
    func testRemovedReviewDecodesToSmart() throws {
        let mode = try JSONDecoder().decode(RankMode.self, from: Data(#""review""#.utf8))
        XCTAssertEqual(mode, .smart)
    }

    func testWholeSettingsDocumentSurvivesARemovedReviewMode() throws {
        let json = """
        {"schemaVersion":3,"settings":{"sortMode":"review","columnCount":2}}
        """
        let payload = try JSONDecoder().decode(SettingsPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.settings.sortMode, .smart)
        XCTAssertEqual(payload.settings.columnCount, 2)
    }

    func testUnknownValueFallsBackInsteadOfThrowing() throws {
        let mode = try JSONDecoder().decode(RankMode.self, from: Data(#""someFutureMode""#.utf8))
        XCTAssertEqual(mode, .smart)
    }

    func testKnownValuesStillRoundTrip() throws {
        for mode in RankMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(RankMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }

    func testWholeSettingsDocumentSurvivesAnOldSortMode() throws {
        let json = """
        {"schemaVersion":3,"settings":{"sortMode":"contextFirst","columnCount":3}}
        """
        let payload = try JSONDecoder().decode(SettingsPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.settings.sortMode, .frequencyDesc)
        XCTAssertEqual(payload.settings.columnCount, 3)
    }

    /// 选项还在，只是又少了一个：其余四种模式都没被误删。
    func testRemainingModesAreIntact() {
        XCTAssertEqual(
            Set(RankMode.allCases.map(\.rawValue)),
            ["smart", "frequencyDesc", "keyOrder", "alphabetical"]
        )
    }
}
