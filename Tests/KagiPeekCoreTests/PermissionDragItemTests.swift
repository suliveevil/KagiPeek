import UniformTypeIdentifiers
import XCTest
@testable import KagiPeekCore

/// The drag payload. These assertions exist because the convenient spelling looks right and
/// is not: `NSItemProvider(contentsOf:)` advertises `com.apple.application-bundle` for an
/// `.app` and then fails to load it, since a bundle is a directory, not a file. The drop is
/// accepted (the password prompt appears) and nothing reaches the list.
final class PermissionDragItemTests: XCTestCase {
    private var bundleURL: URL!

    override func setUpWithError() throws {
        // A directory with an `.app` extension: the same shape as a real bundle, without
        // needing an installed app. UTI detection is by extension.
        bundleURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DragProbe-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bundleURL)
    }

    // MARK: - What the list is offered

    func testAdvertisesBothTypesAPrivacyListMayAskFor() {
        let provider = PermissionDragItem.provider(forAppAt: bundleURL)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.applicationBundle.identifier))
    }

    // MARK: - And both of them load

    func testTheFileURLResolvesToTheBundle() {
        let provider = PermissionDragItem.provider(forAppAt: bundleURL)
        let loaded = expectation(description: "file url loads")
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            XCTAssertNil(error)
            XCTAssertEqual(self.path(of: item), self.bundleURL.standardizedFileURL.path)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
    }

    func testTheBundleLoadsInsteadOfFailingOnADirectory() {
        let provider = PermissionDragItem.provider(forAppAt: bundleURL)
        let loaded = expectation(description: "bundle loads")
        provider.loadItem(forTypeIdentifier: UTType.applicationBundle.identifier, options: nil) { item, error in
            XCTAssertNil(error, "the bundle representation must not fail: \(String(describing: error))")
            XCTAssertEqual(self.path(of: item), self.bundleURL.standardizedFileURL.path)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
    }

    // MARK: - The trap this replaces

    func testTheConvenienceInitialiserCannotServeTheBundleType() {
        // Not a requirement — a recorded measurement. If this ever starts passing, the
        // hand-built provider can be simplified; until then it documents why it exists.
        let convenience = NSItemProvider(contentsOf: bundleURL)
        XCTAssertNotNil(convenience)
        XCTAssertTrue(convenience?.hasItemConformingToTypeIdentifier(UTType.applicationBundle.identifier) ?? false)

        let finished = expectation(description: "convenience load finishes")
        convenience?.loadItem(
            forTypeIdentifier: UTType.applicationBundle.identifier,
            options: nil
        ) { item, error in
            XCTAssertNil(item, "reading a bundle as a file is what fails")
            XCTAssertNotNil(error)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
    }

    private func path(of item: NSSecureCoding?) -> String? {
        switch item {
        case let url as URL:
            return url.standardizedFileURL.path
        case let data as Data:
            return URL(dataRepresentation: data, relativeTo: nil)?.standardizedFileURL.path
        case let text as String:
            return URL(string: text)?.standardizedFileURL.path
        default:
            return nil
        }
    }
}
