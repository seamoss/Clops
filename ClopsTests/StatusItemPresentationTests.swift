import AppKit
import XCTest
@testable import Clops

@MainActor
final class StatusItemPresentationTests: XCTestCase {
    func testBrandedAssetsAreBundledAsTemplates() throws {
        for name in [
            StatusItemPresentation.idleAssetName,
            StatusItemPresentation.copyFeedbackAssetName,
        ] {
            let image = try XCTUnwrap(NSImage(named: name), "Missing asset: \(name)")
            XCTAssertTrue(image.isTemplate)
            XCTAssertFalse(image.representations.isEmpty)
        }
    }

    func testIdlePresentationUsesBrandedTemplateAtStableSize() {
        let presentation = StatusItemPresentation(
            paused: false,
            copyFeedback: false,
            shortcutLabel: "⌥V"
        )

        XCTAssertEqual(presentation.state, .idle)
        XCTAssertEqual(presentation.image.size, StatusItemPresentation.imageSize)
        XCTAssertTrue(presentation.image.isTemplate)
        XCTAssertEqual(presentation.image.accessibilityDescription, "Clops clipboard history")
        XCTAssertEqual(presentation.toolTip, "Clops Clipboard History (⌥V)")
        XCTAssertEqual(presentation.accessibilityValue, "Capture active")
        XCTAssertFalse(presentation.shouldPulse)
    }

    func testCopyFeedbackUsesCapturedAssetAndRequestsPulse() {
        var requestedNames: [NSImage.Name] = []
        let source = NSImage(size: NSSize(width: 12, height: 12))
        let presentation = StatusItemPresentation(
            paused: false,
            copyFeedback: true,
            shortcutLabel: nil,
            namedImageLoader: {
                requestedNames.append($0)
                return source
            }
        )

        XCTAssertEqual(requestedNames, [StatusItemPresentation.copyFeedbackAssetName])
        XCTAssertEqual(presentation.state, .copyFeedback)
        XCTAssertEqual(presentation.image.size, StatusItemPresentation.imageSize)
        XCTAssertTrue(presentation.image.isTemplate)
        XCTAssertEqual(presentation.image.accessibilityDescription, "Clops, copy captured")
        XCTAssertEqual(presentation.accessibilityValue, "Copy captured")
        XCTAssertTrue(presentation.shouldPulse)

        XCTAssertEqual(source.size, NSSize(width: 12, height: 12))
        XCTAssertFalse(source.isTemplate, "The cached source image must not be mutated")
    }

    func testPausedStateWinsOverTransientCopyFeedback() {
        var requestedSymbolName: String?
        let presentation = StatusItemPresentation(
            paused: true,
            copyFeedback: true,
            shortcutLabel: "⌥V",
            namedImageLoader: { _ in
                XCTFail("Paused state should not load a branded asset")
                return nil
            },
            symbolImageLoader: { name, _ in
                requestedSymbolName = name
                return NSImage(size: NSSize(width: 16, height: 16))
            }
        )

        XCTAssertEqual(presentation.state, .paused)
        XCTAssertEqual(requestedSymbolName, "pause.circle.fill")
        XCTAssertEqual(presentation.toolTip, "Clops — Capture Paused (⌥V)")
        XCTAssertEqual(presentation.accessibilityValue, "Capture paused")
        XCTAssertFalse(presentation.shouldPulse)
    }

    func testMissingBrandedAssetFallsBackToClipboardSymbol() {
        var requestedSymbolName: String?
        let presentation = StatusItemPresentation(
            paused: false,
            copyFeedback: false,
            shortcutLabel: nil,
            namedImageLoader: { _ in nil },
            symbolImageLoader: { name, _ in
                requestedSymbolName = name
                return NSImage(size: NSSize(width: 16, height: 16))
            }
        )

        XCTAssertEqual(requestedSymbolName, "clipboard")
        XCTAssertEqual(presentation.image.size, StatusItemPresentation.imageSize)
        XCTAssertTrue(presentation.image.isTemplate)
    }

    func testCopyPulsePeakIsBoundedForBursts() {
        XCTAssertEqual(StatusItemPresentation.copyPulsePeak(burstCount: 0), 1.14)
        XCTAssertEqual(StatusItemPresentation.copyPulsePeak(burstCount: 1), 1.14)
        XCTAssertEqual(StatusItemPresentation.copyPulsePeak(burstCount: 2), 1.16)
        XCTAssertEqual(StatusItemPresentation.copyPulsePeak(burstCount: 4), 1.20)
        XCTAssertEqual(StatusItemPresentation.copyPulsePeak(burstCount: 100), 1.20)
    }
}
