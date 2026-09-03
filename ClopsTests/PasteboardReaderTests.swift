import AppKit
import XCTest
@testable import Clops

@MainActor
final class PasteboardReaderTests: XCTestCase {
    func testReadsPlainText() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("A useful copy", forType: .string)

        let payload = PasteboardReader.read(from: pasteboard, captureImages: true, captureFiles: true)

        XCTAssertEqual(payload, .text(plain: "A useful copy", rtf: nil, html: nil))
    }

    func testSkipsConcealedContent() {
        let pasteboard = NSPasteboard.withUniqueName()
        let item = NSPasteboardItem()
        item.setString("secret", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let payload = PasteboardReader.read(from: pasteboard, captureImages: true, captureFiles: true)

        XCTAssertNil(payload)
    }

    func testReadsFinderFileURLs() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try Data("file contents".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))

        let payload = PasteboardReader.read(from: pasteboard, captureImages: true, captureFiles: true)

        guard case let .files(references) = payload else {
            return XCTFail("Expected a file payload")
        }
        XCTAssertEqual(references.map(\.url), [fileURL.standardizedFileURL])
        XCTAssertTrue(references.allSatisfy { $0.bookmarkData != nil })

        var writablePayload = try XCTUnwrap(payload)
        let destinationPasteboard = NSPasteboard.withUniqueName()
        XCTAssertTrue(writablePayload.write(to: destinationPasteboard))
        let writtenURLs = (destinationPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []).compactMap { $0 as? URL }
        XCTAssertEqual(writtenURLs.map(\.standardizedFileURL), [fileURL.standardizedFileURL])
    }
}
