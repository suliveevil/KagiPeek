import XCTest
@testable import KagiPeekCore

final class PanelThemeTests: XCTestCase {
    private func decode(_ raw: String) throws -> PanelTheme {
        try JSONDecoder().decode(PanelTheme.self, from: Data("\"\(raw)\"".utf8))
    }

    /// The three old look names each land on the appearance they were: two dark, one light.
    /// A stored graphite panel must not come back as the new default (system) and flip on a
    /// light Mac.
    func testOldLookNamesMigrateToTheirAppearance() throws {
        XCTAssertEqual(try decode("graphite"), .dark)
        XCTAssertEqual(try decode("midnight"), .dark)
        XCTAssertEqual(try decode("paper"), .light)
    }

    func testCurrentNamesDecodeAsThemselves() throws {
        XCTAssertEqual(try decode("system"), .system)
        XCTAssertEqual(try decode("light"), .light)
        XCTAssertEqual(try decode("dark"), .dark)
    }

    /// A value this build does not know follows the system: the least surprising answer.
    func testUnknownValueFallsBackToSystem() throws {
        XCTAssertEqual(try decode("cobalt"), .system)
    }

    func testEncodingUsesTheCurrentNames() throws {
        let data = try JSONEncoder().encode([PanelTheme.light, .dark, .system])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[\"light\",\"dark\",\"system\"]")
    }
}
