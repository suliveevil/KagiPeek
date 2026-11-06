import AppKit
import XCTest

/// What a drag has to put on the pasteboard for System Settings' privacy lists to accept an
/// app. Finder writes the file URL **and** the legacy `NSFilenamesPboardType` path array; an
/// `NSItemProvider` cannot write the latter, which is why the guide starts a real dragging
/// session with the URL as its pasteboard writer.
final class AppDragPasteboardContractTests: XCTestCase {
    private var bundleURL: URL!

    override func setUpWithError() throws {
        bundleURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DragContract-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bundleURL)
    }

    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.suliveevil.kaname.tests.\(UUID().uuidString)"))
    }

    func testTheURLWriterCarriesTheFileURLAndTheLegacyPathArray() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()

        XCTAssertTrue(pasteboard.writeObjects([bundleURL as NSURL]))

        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        XCTAssertTrue(types.contains(NSPasteboard.PasteboardType.fileURL.rawValue))
        // The one an item provider cannot write, and the reason a drop can be accepted
        // (pointer shows a +) and still add nothing.
        XCTAssertTrue(types.contains("NSFilenamesPboardType"))
    }

    func testTheDroppedURLReadsBackAsAFileURL() {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([bundleURL as NSURL]))

        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertEqual(urls?.count, 1)
        XCTAssertEqual(urls?.first?.standardizedFileURL.path, bundleURL.standardizedFileURL.path)
    }

    func testAnItemProviderCannotWriteTheLegacyFlavour() {
        // A recorded measurement, not a requirement: if this ever fails, the drag source can
        // go back to `.onDrag`, and until then it documents why it does not.
        guard let provider = NSItemProvider(contentsOf: bundleURL) else {
            return XCTFail("expected a provider for a directory with an .app extension")
        }
        XCTAssertFalse(provider.registeredTypeIdentifiers.contains("NSFilenamesPboardType"))
    }
}
