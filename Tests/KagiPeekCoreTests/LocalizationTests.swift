import XCTest
@testable import KagiPeekCore

final class LocalizationTests: XCTestCase {
    func testEveryKeyHasBothLanguages() {
        for key in L10nKey.allCases {
            let en = L10n.string(key, language: .english)
            let zh = L10n.string(key, language: .chinese)
            XCTAssertFalse(en.isEmpty, "\(key) has no English translation")
            XCTAssertFalse(zh.isEmpty, "\(key) has no Chinese translation")
            XCTAssertNotEqual(en, key.rawValue, "\(key) fell back to its raw name")
        }
    }

    func testFormatPlaceholdersMatch() {
        for key in L10nKey.allCases {
            let en = L10n.string(key, language: .english)
            let zh = L10n.string(key, language: .chinese)
            XCTAssertEqual(placeholderCount(en), placeholderCount(zh), "\(key) placeholder mismatch")
        }
    }

    func testSystemLanguageResolution() {
        XCTAssertEqual(L10n.resolvedLanguage(.system, preferred: ["zh-Hans-CN", "en"]), .chinese)
        XCTAssertEqual(L10n.resolvedLanguage(.system, preferred: ["en-US"]), .english)
        XCTAssertEqual(L10n.resolvedLanguage(.english, preferred: ["zh-Hans"]), .english)
    }

    private func placeholderCount(_ text: String) -> Int {
        let regex = try! NSRegularExpression(pattern: "%[@d%]")
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
