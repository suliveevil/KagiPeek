import XCTest
@testable import KagiPeekCore

/// The tap's failure line is the only evidence a freeze leaves behind, so its shape is part
/// of the contract: every investigation so far — eleven `attempt 1`s, `trusted=true` through
/// five revocations, a `stood_ms` of two milliseconds — was read off this string.
final class TapDiagnosticsTests: XCTestCase {
    func testTheReEnableLineKeepsItsFieldOrderAndWording() {
        let report = TapDiagnostics(
            trigger: .timeout,
            attempt: 1,
            trusted: true,
            enabled: false,
            stoodForMilliseconds: 1234,
            recovery: .reEnable(after: 0)
        )
        XCTAssertEqual(
            report.line,
            "event tap disabled by the system (timeout); attempt 1, trusted=true, "
                + "enabled=false, stood_ms=1234 — re-enabling in 0.0s"
        )
    }

    func testAnUnknownStandTimePrintsAQuestionMarkRatherThanZero() {
        // Zero would read as "the tap never stood at all", which is a different diagnosis
        // from "we never recorded an enable".
        let report = TapDiagnostics(
            trigger: .timeout,
            attempt: 2,
            trusted: true,
            enabled: true,
            stoodForMilliseconds: nil,
            recovery: .tearDown
        )
        XCTAssertTrue(report.line.contains("stood_ms=? — giving up"), report.line)
    }

    func testTheTeardownDetailDoesNotRepeatTheVerdict() {
        // The teardown log line already says "event tap torn down"; appending "giving up"
        // would say it twice and make the line harder to read, not more informative.
        let report = TapDiagnostics(
            trigger: .userInput,
            attempt: 3,
            trusted: false,
            enabled: true,
            stoodForMilliseconds: 42,
            recovery: .tearDown
        )
        XCTAssertEqual(
            report.detail,
            "event tap disabled by the system (user input); attempt 3, trusted=false, "
                + "enabled=true, stood_ms=42"
        )
        XCTAssertEqual(report.line, report.detail + " — giving up")
    }

    func testUntrustedIsReportedEvenWhenTheSystemStillThinksTheTapIsEnabled() {
        // The two flags disagreeing is the only way to tell "our tap is stale" from "the
        // system is refusing events", which is why both are recorded rather than inferred.
        let report = TapDiagnostics(
            trigger: .timeout,
            attempt: 1,
            trusted: false,
            enabled: true,
            stoodForMilliseconds: 0,
            recovery: .tearDown
        )
        XCTAssertTrue(report.line.contains("trusted=false, enabled=true"), report.line)
    }
}
