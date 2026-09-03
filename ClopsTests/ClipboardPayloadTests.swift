import XCTest
import AppKit
@testable import Clops

final class ClipboardPayloadTests: XCTestCase {
    func testPayloadCodableRoundTrip() throws {
        let payloads: [ClipboardPayload] = [
            .text(plain: "Hello, Clops", rtf: Data([1, 2]), html: Data([3, 4])),
            .image(data: Data([137, 80, 78, 71]), typeIdentifier: "public.png"),
            .files([
                ClipboardFileReference(url: URL(fileURLWithPath: "/tmp/one.txt")),
                ClipboardFileReference(url: URL(fileURLWithPath: "/tmp/two.txt"))
            ])
        ]

        let data = try JSONEncoder().encode(payloads)
        let decoded = try JSONDecoder().decode([ClipboardPayload].self, from: data)
        XCTAssertEqual(decoded, payloads)
    }

    func testFingerprintIsStableAndContentSensitive() {
        let first = ClipboardPayload.text(plain: "hello", rtf: nil, html: nil)
        let same = ClipboardPayload.text(plain: "hello", rtf: nil, html: nil)
        let different = ClipboardPayload.text(plain: "hello!", rtf: nil, html: nil)

        XCTAssertEqual(first.fingerprint, same.fingerprint)
        XCTAssertNotEqual(first.fingerprint, different.fingerprint)
    }

    func testTextFingerprintIgnoresAlternateRepresentations() {
        let rich = ClipboardPayload.text(
            plain: "same text",
            rtf: Data("volatile rtf".utf8),
            html: Data("<b>same text</b>".utf8)
        )
        let plain = ClipboardPayload.text(plain: "same text", rtf: nil, html: nil)

        XCTAssertEqual(rich.fingerprint, plain.fingerprint)
    }

    func testTextFingerprintPreservesExactPlainText() {
        let values = ["A", "a", "A ", "A\n"]
        let fingerprints = Set(values.map {
            ClipboardPayload.text(plain: $0, rtf: nil, html: nil).fingerprint
        })

        XCTAssertEqual(fingerprints.count, values.count)
    }

    func testFileFingerprintDoesNotDependOnBookmarkEncoding() {
        let url = URL(fileURLWithPath: "/tmp/example.txt")
        let first = ClipboardPayload.files([
            ClipboardFileReference(url: url, bookmarkData: Data([1, 2, 3]))
        ])
        let second = ClipboardPayload.files([
            ClipboardFileReference(url: url, bookmarkData: Data([9, 8, 7]))
        ])

        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    func testFileFingerprintPreservesPasteOrder() {
        let firstURL = URL(fileURLWithPath: "/tmp/first.txt")
        let secondURL = URL(fileURLWithPath: "/tmp/second.txt")
        let forward = ClipboardPayload.files([
            ClipboardFileReference(url: firstURL),
            ClipboardFileReference(url: secondURL),
        ])
        let reversed = ClipboardPayload.files([
            ClipboardFileReference(url: secondURL),
            ClipboardFileReference(url: firstURL),
        ])

        XCTAssertNotEqual(forward.fingerprint, reversed.fingerprint)
    }

    func testImageFingerprintRemainsByteAndTypeExact() {
        let png = ClipboardPayload.image(data: Data([1, 2, 3]), typeIdentifier: "public.png")
        let samePNG = ClipboardPayload.image(data: Data([1, 2, 3]), typeIdentifier: "public.png")
        let changedPNG = ClipboardPayload.image(data: Data([1, 2, 4]), typeIdentifier: "public.png")
        let tiff = ClipboardPayload.image(data: Data([1, 2, 3]), typeIdentifier: "public.tiff")

        XCTAssertEqual(png.fingerprint, samePNG.fingerprint)
        XCTAssertNotEqual(png.fingerprint, changedPNG.fingerprint)
        XCTAssertNotEqual(png.fingerprint, tiff.fingerprint)
    }

    func testDecodesLegacyFileURLPayload() throws {
        let data = Data(#"{"kind":"files","urls":["file:///tmp/legacy.txt"]}"#.utf8)
        let payload = try JSONDecoder().decode(ClipboardPayload.self, from: data)

        XCTAssertEqual(payload.plainText, "/tmp/legacy.txt")
    }

    @MainActor
    func testFileWriteFailsClosedWithoutBookmarkAndPreservesPasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)
        var payload = ClipboardPayload.files([
            ClipboardFileReference(url: URL(fileURLWithPath: "/tmp/legacy.txt"))
        ])

        XCTAssertFalse(payload.write(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    @MainActor
    func testFileWritePreflightsEveryReferenceBeforeClearingPasteboard() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try Data("file contents".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let validReference = try XCTUnwrap(ClipboardFileReference.capture(fileURL))
        let invalidReference = ClipboardFileReference(
            url: URL(fileURLWithPath: "/tmp/untrusted.txt"),
            bookmarkData: Data([1, 2, 3])
        )
        var payload = ClipboardPayload.files([validReference, invalidReference])
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("keep me", forType: .string)

        XCTAssertFalse(payload.write(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }
}
