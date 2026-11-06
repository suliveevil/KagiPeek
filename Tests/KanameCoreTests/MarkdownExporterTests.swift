import XCTest
@testable import KanameCore

final class MarkdownExporterTests: XCTestCase {
    func testRendersGroupedTable() {
        let items = [
            BindingItem(chord: .combo([.command], KeyToken("c")), title: "Copy | Paste", group: ["Edit"], source: .menu),
            BindingItem(chord: .combo([.command, .shift], KeyToken("s")), title: "Save As", group: ["File"], isEnabled: false, source: .menu)
        ]
        let markdown = MarkdownExporter.render(
            appName: "Demo",
            items: items,
            style: .symbols,
            language: .english,
            generatedAt: Date(timeIntervalSince1970: 0),
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertTrue(markdown.contains("# Kaname — Demo"))
        XCTAssertTrue(markdown.contains("## Edit"))
        XCTAssertTrue(markdown.contains("## File"))
        XCTAssertTrue(markdown.contains("| `⌘C` | Copy \\| Paste |"))
        XCTAssertTrue(markdown.contains("Save As _(unavailable)_"))
    }
}
