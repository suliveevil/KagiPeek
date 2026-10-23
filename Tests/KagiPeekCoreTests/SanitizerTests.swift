import XCTest
@testable import KagiPeekCore

// 本文件钉住「写入磁盘之前一定脱敏」这条契约。脱敏规则的取舍是保守的：误伤只损失一点
// 调试信息，漏放则可能把用户的令牌写进一个准备发出去的文件里。

final class SanitizerTests: XCTestCase {
    func testRedactsSensitiveURLQueryValues() {
        let line = "GET https://api.example.com/v1/search?q=secret&token=abc123"
        let result = Sanitizer.redact(line)
        XCTAssertFalse(result.contains("secret"))
        XCTAssertFalse(result.contains("abc123"))
        XCTAssertTrue(result.contains("<query>"))
        // host 要留下：脱敏的是参数，不是这行日志的定位价值。
        XCTAssertTrue(result.contains("api.example.com"))
    }

    func testQueryWithoutEqualsIsLeftAlone() {
        // 正文里出现的问号不是 URL 参数，不该被吃掉。
        let result = Sanitizer.redact("why?because")
        XCTAssertEqual(result, "why?because")
    }

    func testRedactsBearerAndBasicCredentials() {
        let bearer = Sanitizer.redact("Authorization: Bearer abcdef1234567890")
        XCTAssertFalse(bearer.contains("abcdef1234567890"))
        XCTAssertTrue(bearer.localizedCaseInsensitiveContains("bearer"))

        let basic = Sanitizer.redact("basic dXNlcjpwYXNzd29yZA==")
        XCTAssertFalse(basic.contains("dXNlcjpwYXNzd29yZA"))
    }

    func testRedactsBareKeyValuePairs() {
        let result = Sanitizer.redact("token: ghp_0123456789abcdef")
        XCTAssertFalse(result.contains("ghp_0123456789abcdef"))
        XCTAssertTrue(result.contains("<redacted>"))
    }

    func testRedactsEmailAddresses() {
        let result = Sanitizer.redact("contact someone@example.com about it")
        XCTAssertFalse(result.contains("someone@example.com"))
        XCTAssertTrue(result.contains("<email>"))
    }

    func testRedactsLongHexStrings() {
        let hash = "0123456789abcdef0123456789abcdef"
        let result = Sanitizer.redact("digest \(hash)")
        XCTAssertFalse(result.contains(hash))
        XCTAssertTrue(result.contains("<hex>"))
    }

    func testShortHexPrefixIsNotMistakenForASecret() {
        // 短键码/版本号这类十六进制不是秘密，误伤会毁掉可读性。
        XCTAssertEqual(Sanitizer.redact("code=0a1b2c3d"), "code=0a1b2c3d")
    }

    func testPlainMessageSurvivesUnchanged() {
        let message = "扫描完成：42 条快捷键 ✓"
        XCTAssertEqual(Sanitizer.redact(message), message)
    }

    func testMultiplePatternsInOneLineAreAllHandled() {
        let line = "user=a@b.com token=deadbeefdeadbeefdeadbeefdeadbeef"
        let result = Sanitizer.redact(line)
        XCTAssertFalse(result.contains("a@b.com"))
        XCTAssertFalse(result.contains("deadbeefdeadbeefdeadbeefdeadbeef"))
    }

    func testRedactionIsIdempotent() {
        let once = Sanitizer.redact("token=abc123 email x@y.com")
        XCTAssertEqual(Sanitizer.redact(once), once)
    }

    func testHomeDirectoryBecomesTilde() {
        let prepared = Sanitizer.prepare(
            "/Users/someone/Library/Application Support/KagiPeek/logs",
            homePrefix: "/Users/someone"
        )
        XCTAssertEqual(prepared, "~/Library/Application Support/KagiPeek/logs")
        XCTAssertFalse(prepared.contains("someone"))
    }

    func testControlCharactersCannotForgeASecondLine() {
        let prepared = Sanitizer.prepare("first\nsecond\rambient\u{7F}")
        XCTAssertFalse(prepared.contains("\n"))
        XCTAssertFalse(prepared.contains("\r"))
    }

    func testClampKeepsTitlesShort() {
        let long = String(repeating: "字", count: 200)
        let clamped = Sanitizer.clamp(long, limit: 80)
        XCTAssertEqual(clamped.count, 80)
        XCTAssertTrue(clamped.hasSuffix("…"))
        XCTAssertEqual(Sanitizer.clamp("short"), "short")
    }
}
