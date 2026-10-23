import XCTest
@testable import KagiPeekCore

// 级别门槛只有一道判断，但它决定了「出问题时日志会不会恰好静默」：
// 失败永远是 I/W/E，任何开关都不影响；verbose/debug 才是可关的。

final class LogLevelFilterTests: XCTestCase {
    func testErrorsAlwaysPass() {
        XCTAssertTrue(LogLevelFilter.shouldLog(level: .error, verboseEnabled: false))
        XCTAssertTrue(LogLevelFilter.shouldLog(level: .warning, verboseEnabled: false))
    }

    func testInfoPassesWithVerboseOff() {
        XCTAssertTrue(LogLevelFilter.shouldLog(level: .info, verboseEnabled: false))
    }

    func testDebugNeedsVerbose() {
        XCTAssertFalse(LogLevelFilter.shouldLog(level: .debug, verboseEnabled: false))
        XCTAssertTrue(LogLevelFilter.shouldLog(level: .debug, verboseEnabled: true))
    }

    func testVerboseLevelNeedsVerbose() {
        XCTAssertFalse(LogLevelFilter.shouldLog(level: .verbose, verboseEnabled: false))
        XCTAssertTrue(LogLevelFilter.shouldLog(level: .verbose, verboseEnabled: true))
    }

    func testLevelOrderingIsSevereLast() {
        XCTAssertTrue(DiagLevel.verbose < DiagLevel.debug)
        XCTAssertTrue(DiagLevel.debug < DiagLevel.info)
        XCTAssertTrue(DiagLevel.info < DiagLevel.warning)
        XCTAssertTrue(DiagLevel.warning < DiagLevel.error)
    }

    func testLevelCharactersAreOneLetterEach() {
        XCTAssertEqual(DiagLevel.allCases.map(\.character), ["V", "D", "I", "W", "E"])
    }

    func testTagKeywordsSurviveInLogLines() {
        // 关键字就是 grep 入口，改一个字母就会让排查手册失效。
        XCTAssertEqual(DiagTag.tap.keyword, "[tap]")
        XCTAssertEqual(DiagTag.inject.keyword, "[inject]")
        XCTAssertEqual(DiagTag.perm.keyword, "[perm]")
    }
}
