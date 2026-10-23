import XCTest
@testable import KagiPeekCore

// `contextFirst` 被删掉了（它和 `frequencyDesc` 得分完全相同，是个改了没反应的选项）。
// 但已经存在的 settings.json 里可能还写着它——解码必须软着陆，
// 因为这里一旦抛错，整份设置文件会被 JsonFileStore 当成损坏文件挪走。

final class RankModeCompatibilityTests: XCTestCase {
    func testRemovedContextFirstDecodesToFrequency() throws {
        let mode = try JSONDecoder().decode(RankMode.self, from: Data(#""contextFirst""#.utf8))
        XCTAssertEqual(mode, .frequencyDesc)
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

    /// 选项还在，只是少了一个：其余五种模式都没被误删。
    func testRemainingModesAreIntact() {
        XCTAssertEqual(
            Set(RankMode.allCases.map(\.rawValue)),
            ["smart", "frequencyDesc", "review", "keyOrder", "alphabetical"]
        )
    }
}
