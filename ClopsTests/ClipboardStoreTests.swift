import CryptoKit
@preconcurrency import Security
import XCTest
@testable import Clops

@MainActor
final class ClipboardStoreTests: XCTestCase {
    func testDuplicateMovesToTopAndKeepsPin() throws {
        let store = makeStore()
        let now = Date.now
        let firstOutcome = try XCTUnwrap(store.captureWithOutcome(
            .text(plain: "first", rtf: nil, html: nil),
            sourceAppName: "Notes",
            sourceBundleIdentifier: nil,
            at: now.addingTimeInterval(-3)
        ))
        let first = firstOutcome.entry
        XCTAssertEqual(firstOutcome.disposition, .inserted)
        store.togglePinned(first.id)
        store.markUsed(first.id, at: now.addingTimeInterval(-2))
        _ = store.capture(
            .text(plain: "second", rtf: nil, html: nil),
            sourceAppName: "Safari",
            sourceBundleIdentifier: nil,
            at: now.addingTimeInterval(-1)
        )

        let refreshedOutcome = try XCTUnwrap(store.captureWithOutcome(
            .text(plain: "first", rtf: nil, html: nil),
            sourceAppName: "Xcode",
            sourceBundleIdentifier: nil,
            at: now
        ))
        let refreshed = refreshedOutcome.entry

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.first?.id, first.id)
        XCTAssertEqual(refreshed.id, first.id)
        XCTAssertEqual(refreshedOutcome.disposition, .resurfaced)
        XCTAssertTrue(refreshed.isPinned)
        XCTAssertEqual(refreshed.capturedAt, now)
        XCTAssertNil(refreshed.lastUsedAt)
        XCTAssertEqual(refreshed.sourceAppName, "Xcode")
    }

    func testRichAndPlainCopiesResurfaceOneEntryWithLatestPayload() throws {
        let store = makeStore()
        let richPayload = ClipboardPayload.text(
            plain: "same visible text",
            rtf: Data("{\\rtf1 same visible text}".utf8),
            html: Data("<b>same visible text</b>".utf8)
        )
        let plainPayload = ClipboardPayload.text(
            plain: "same visible text",
            rtf: nil,
            html: nil
        )
        let first = try XCTUnwrap(store.capture(
            richPayload,
            sourceAppName: "Pages",
            sourceBundleIdentifier: "com.apple.Pages"
        ))
        _ = store.capture(
            .text(plain: "another item", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        )

        let plainRefresh = try XCTUnwrap(store.captureWithOutcome(
            plainPayload,
            sourceAppName: "TextEdit",
            sourceBundleIdentifier: "com.apple.TextEdit"
        ))

        XCTAssertEqual(plainRefresh.disposition, .resurfaced)
        XCTAssertEqual(plainRefresh.entry.id, first.id)
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.first?.payload, plainPayload)

        let richRefresh = try XCTUnwrap(store.captureWithOutcome(
            richPayload,
            sourceAppName: "Pages",
            sourceBundleIdentifier: "com.apple.Pages"
        ))

        XCTAssertEqual(richRefresh.disposition, .resurfaced)
        XCTAssertEqual(richRefresh.entry.id, first.id)
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.first?.payload, richPayload)
    }

    func testOversizedEquivalentRefreshKeepsAndResurfacesSafePayload() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardStore(
            storageURL: directory.appendingPathComponent("history.clops"),
            fixedEncryptionKey: Data(repeating: 7, count: 32),
            maxStorageBytes: 32
        )
        let safePayload = ClipboardPayload.text(plain: "same", rtf: nil, html: nil)
        let first = try XCTUnwrap(store.capture(
            safePayload,
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        ))
        let other = try XCTUnwrap(store.capture(
            .text(plain: "other", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        ))
        let oversizedPayload = ClipboardPayload.text(
            plain: "same",
            rtf: Data(repeating: 0x41, count: 100),
            html: nil
        )
        let resurfaceDate = Date.now.addingTimeInterval(1)

        let outcome = try XCTUnwrap(store.captureWithOutcome(
            oversizedPayload,
            sourceAppName: "Pages",
            sourceBundleIdentifier: "com.apple.Pages",
            at: resurfaceDate
        ))

        XCTAssertEqual(outcome.disposition, .resurfaced)
        XCTAssertEqual(outcome.entry.id, first.id)
        XCTAssertEqual(store.entries.map(\.id), [first.id, other.id])
        XCTAssertEqual(store.entries.first?.payload, safePayload)
        XCTAssertEqual(store.entries.first?.capturedAt, resurfaceDate)
        XCTAssertEqual(
            store.managementNotice,
            "Existing item resurfaced, but its latest formatting was too large."
        )
    }

    func testLimitTrimsOldestUnpinnedItems() throws {
        let store = makeStore(maxItems: 2)
        _ = store.capture(.text(plain: "one", rtf: nil, html: nil), sourceAppName: nil, sourceBundleIdentifier: nil)
        _ = store.capture(.text(plain: "two", rtf: nil, html: nil), sourceAppName: nil, sourceBundleIdentifier: nil)
        _ = store.capture(.text(plain: "three", rtf: nil, html: nil), sourceAppName: nil, sourceBundleIdentifier: nil)

        XCTAssertEqual(store.entries.map(\.payload.title), ["three", "two"])
    }

    func testClearPreservesPinnedEntries() throws {
        let store = makeStore()
        let pinned = try XCTUnwrap(store.capture(.text(plain: "keep", rtf: nil, html: nil), sourceAppName: nil, sourceBundleIdentifier: nil))
        store.togglePinned(pinned.id)
        _ = store.capture(.text(plain: "remove", rtf: nil, html: nil), sourceAppName: nil, sourceBundleIdentifier: nil)

        store.clearUnpinned()

        XCTAssertEqual(store.entries.map(\.id), [pinned.id])
    }

    func testMarkUsedPersistsRefreshedFileBookmark() throws {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/tmp/example.txt")
        let originalPayload = ClipboardPayload.files([
            ClipboardFileReference(url: url, bookmarkData: Data([1]))
        ])
        let entry = try XCTUnwrap(store.capture(
            originalPayload,
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        ))
        let refreshedPayload = ClipboardPayload.files([
            ClipboardFileReference(url: url, bookmarkData: Data([2]))
        ])

        store.markUsed(entry.id, refreshedPayload: refreshedPayload)

        XCTAssertEqual(store.entries.first?.payload, refreshedPayload)
        XCTAssertEqual(store.entries.first?.fingerprint, refreshedPayload.fingerprint)
    }

    func testMarkUsedConsolidatesARefreshedFileIdentityCollision() throws {
        let store = makeStore()
        let oldURL = URL(fileURLWithPath: "/tmp/old-location.txt")
        let movedURL = URL(fileURLWithPath: "/tmp/new-location.txt")
        let oldEntry = try XCTUnwrap(store.capture(
            .files([ClipboardFileReference(url: oldURL, bookmarkData: Data([1]))]),
            sourceAppName: "Finder",
            sourceBundleIdentifier: "com.apple.finder"
        ))
        let existingDestination = try XCTUnwrap(store.capture(
            .files([ClipboardFileReference(url: movedURL, bookmarkData: Data([2]))]),
            sourceAppName: "Finder",
            sourceBundleIdentifier: "com.apple.finder"
        ))
        store.togglePinned(existingDestination.id)
        let refreshedPayload = ClipboardPayload.files([
            ClipboardFileReference(url: movedURL, bookmarkData: Data([3]))
        ])
        let usedAt = Date.now

        store.markUsed(oldEntry.id, refreshedPayload: refreshedPayload, at: usedAt)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, oldEntry.id)
        XCTAssertEqual(store.entries.first?.payload, refreshedPayload)
        XCTAssertEqual(store.entries.first?.lastUsedAt, usedAt)
        XCTAssertTrue(store.entries.first?.isPinned == true)
    }

    func testMarkUsedCannotEnlargePinnedBookmarkPastEncodedBudget() throws {
        let store = makeBudgetStore(encodedBytes: 6_000)
        let url = URL(fileURLWithPath: "/tmp/pinned-example.txt")
        let originalPayload = ClipboardPayload.files([
            ClipboardFileReference(url: url, bookmarkData: Data([1]))
        ])
        let entry = try XCTUnwrap(store.capture(
            originalPayload,
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        ))
        store.togglePinned(entry.id)
        let oversizedRefresh = ClipboardPayload.files([
            ClipboardFileReference(url: url, bookmarkData: Data(repeating: 0xFF, count: 1_000))
        ])

        store.markUsed(entry.id, refreshedPayload: oversizedRefresh)

        XCTAssertEqual(store.entries.first?.payload, originalPayload)
        XCTAssertTrue(store.entries.first?.isPinned == true)
        XCTAssertEqual(
            store.managementNotice,
            "Pinned item kept, but its update exceeded the safety limit."
        )
    }

    func testOversizedFileIdentityRefreshResurfacesSafeMatchingEntry() throws {
        let store = makeBudgetStore(encodedBytes: 12_000)
        let oldURL = URL(fileURLWithPath: "/tmp/old-oversized-location.txt")
        let destinationURL = URL(fileURLWithPath: "/tmp/existing-safe-location.txt")
        let oldPayload = ClipboardPayload.files([
            ClipboardFileReference(url: oldURL, bookmarkData: Data([1]))
        ])
        let safeDestinationPayload = ClipboardPayload.files([
            ClipboardFileReference(url: destinationURL, bookmarkData: Data([2]))
        ])
        let oldEntry = try XCTUnwrap(store.capture(
            oldPayload,
            sourceAppName: "Finder",
            sourceBundleIdentifier: "com.apple.finder"
        ))
        let safeDestination = try XCTUnwrap(store.capture(
            safeDestinationPayload,
            sourceAppName: "Finder",
            sourceBundleIdentifier: "com.apple.finder"
        ))
        store.togglePinned(safeDestination.id)
        let oversizedResolvedPayload = ClipboardPayload.files([
            ClipboardFileReference(
                url: destinationURL,
                bookmarkData: Data(repeating: 0xFF, count: 8_000)
            )
        ])
        let usedAt = Date.now

        let resurfaced = try XCTUnwrap(store.markUsed(
            oldEntry.id,
            refreshedPayload: oversizedResolvedPayload,
            at: usedAt
        ))

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(resurfaced.id, safeDestination.id)
        XCTAssertEqual(store.entries.first?.id, safeDestination.id)
        XCTAssertEqual(store.entries.first?.payload, safeDestinationPayload)
        XCTAssertEqual(store.entries.first?.lastUsedAt, usedAt)
        XCTAssertTrue(store.entries.first?.isPinned == true)
        XCTAssertEqual(
            store.managementNotice,
            "Pinned item kept, but its update exceeded the safety limit."
        )
    }

    func testDuplicateCaptureCannotEnlargePinnedBookmarkPastEncodedBudget() throws {
        let store = makeBudgetStore(encodedBytes: 6_000)
        let url = URL(fileURLWithPath: "/tmp/duplicate-example.txt")
        let originalPayload = ClipboardPayload.files([
            ClipboardFileReference(url: url, bookmarkData: Data([1]))
        ])
        let entry = try XCTUnwrap(store.capture(
            originalPayload,
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        ))
        store.togglePinned(entry.id)
        let oversizedDuplicate = ClipboardPayload.files([
            ClipboardFileReference(url: url, bookmarkData: Data(repeating: 0xFF, count: 1_000))
        ])

        let captured = try XCTUnwrap(store.capture(
            oversizedDuplicate,
            sourceAppName: "Finder",
            sourceBundleIdentifier: "com.apple.finder"
        ))

        XCTAssertEqual(captured.id, entry.id)
        XCTAssertEqual(store.entries.first?.payload, originalPayload)
        XCTAssertTrue(store.entries.first?.isPinned == true)
        XCTAssertEqual(
            store.managementNotice,
            "Pinned item kept, but its update exceeded the safety limit."
        )
    }

    func testCaptureIsFrozenDuringTermination() {
        let store = makeStore()
        store.prepareForTermination()

        let captured = store.capture(
            .text(plain: "too late", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        )

        XCTAssertNil(captured)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testUnavailableStorageQuitsCleanlyWhenNothingChanged() async {
        let store = ClipboardStore(persistence: LoadFailingHistoryPersistence())
        await waitUntilLoaded(store)

        guard case .success = await store.flushPersistence() else {
            return XCTFail("An unchanged, unavailable store has nothing to discard")
        }
        XCTAssertNotNil(store.persistenceError)
    }

    func testUnavailableStorageStillRejectsFlushAfterCapture() async {
        let store = ClipboardStore(persistence: LoadFailingHistoryPersistence())
        await waitUntilLoaded(store)
        _ = store.capture(
            .text(plain: "unsaved", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        )

        guard case .failure = await store.flushPersistence() else {
            return XCTFail("In-memory clipboard changes must still block a silent quit")
        }
    }

    func testUnavailableStorageQuitsCleanlyAfterNoOpChanges() async {
        let store = ClipboardStore(
            maxStorageBytes: 1,
            persistence: LoadFailingHistoryPersistence()
        )
        await waitUntilLoaded(store)

        store.updateLimits(maxHistoryItems: 100, retentionDays: 7)
        let rejected = store.capture(
            .text(plain: "too large", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        )

        XCTAssertNil(rejected)
        XCTAssertTrue(store.entries.isEmpty)
        guard case .success = await store.flushPersistence() else {
            return XCTFail("Preferences and rejected entries do not create discardable history")
        }
    }

    func testUnpinnedLimitNeverEvictsPinnedEntries() throws {
        let store = makeStore(maxItems: 1)
        let pinned = try XCTUnwrap(store.capture(
            .text(plain: "pinned", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        ))
        store.togglePinned(pinned.id)
        _ = store.capture(.text(plain: "older", rtf: nil, html: nil), sourceAppName: nil, sourceBundleIdentifier: nil)
        _ = store.capture(.text(plain: "newer", rtf: nil, html: nil), sourceAppName: nil, sourceBundleIdentifier: nil)

        XCTAssertTrue(store.entries.contains { $0.id == pinned.id && $0.isPinned })
        XCTAssertEqual(store.entries.filter { !$0.isPinned }.map(\.payload.title), ["newer"])
    }

    func testCaptureReportsWhenPinnedHistoryConsumesCapacity() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardStore(
            storageURL: directory.appendingPathComponent("history.clops"),
            fixedEncryptionKey: Data(repeating: 3, count: 32),
            maxStorageBytes: 10,
            hardEntryLimit: 20
        )
        let pinned = try XCTUnwrap(store.capture(
            .text(plain: "123456", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        ))
        store.togglePinned(pinned.id)

        let rejected = store.capture(
            .text(plain: "abcde", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        )

        XCTAssertNil(rejected)
        XCTAssertEqual(store.managementNotice, "Not saved — pinned history is full.")
        XCTAssertEqual(store.entries.map(\.id), [pinned.id])
    }

    func testJSONEscapingBudgetRejectsPathologicalControlText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ClipboardStore(
            storageURL: directory.appendingPathComponent("history.clops"),
            fixedEncryptionKey: Data(repeating: 5, count: 32),
            maxStorageBytes: 100_000,
            maxEncodedStorageBytes: 7_000
        )
        let safeText = String(repeating: "a", count: 1_000)
        let controlText = String(repeating: "\0", count: 1_000)
        XCTAssertEqual(safeText.utf8.count, controlText.utf8.count)

        let safeEntry = try XCTUnwrap(store.capture(
            .text(plain: safeText, rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        ))
        store.delete(safeEntry.id)

        let rejected = store.capture(
            .text(plain: controlText, rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        )

        XCTAssertNil(rejected)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.managementNotice, "Not saved — this clipboard item is too large.")
    }

    func testStartupDuplicatePreservesPersistedPinAndIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.clops")
        let key = Data(repeating: 4, count: 32)
        var persisted = ClipboardEntry(
            payload: .text(
                plain: "same",
                rtf: Data("legacy rich representation".utf8),
                html: nil
            ),
            capturedAt: .distantPast,
            lastUsedAt: .distantPast,
            sourceAppName: "Old App",
            isPinned: true
        )
        persisted.fingerprint = "legacy-exact-rich-fingerprint"
        try await HistoryPersistence(storageURL: url, fixedKeyData: key).save([persisted])

        let store = ClipboardStore(storageURL: url, fixedEncryptionKey: key)
        _ = store.capture(
            .text(plain: "same", rtf: nil, html: nil),
            sourceAppName: "New App",
            sourceBundleIdentifier: "example.new"
        )
        await waitUntilLoaded(store)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.id, persisted.id)
        XCTAssertTrue(store.entries.first?.isPinned == true)
        XCTAssertEqual(store.entries.first?.sourceAppName, "New App")
        XCTAssertEqual(store.entries.first?.mostRecentDate, store.entries.first?.capturedAt)
    }

    func testStartupCollapsesLegacyRichTextDuplicatesAndRewritesHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.clops")
        let key = Data(repeating: 8, count: 32)
        let now = Date.now
        var newest = ClipboardEntry(
            payload: .text(
                plain: "duplicate",
                rtf: Data("new rtf".utf8),
                html: Data("<b>duplicate</b>".utf8)
            ),
            capturedAt: now,
            sourceAppName: "Newest App"
        )
        newest.fingerprint = "legacy-rich-fingerprint"
        var olderPinned = ClipboardEntry(
            payload: .text(plain: "duplicate", rtf: nil, html: nil),
            capturedAt: now.addingTimeInterval(-10),
            lastUsedAt: now.addingTimeInterval(-5),
            sourceAppName: "Older App",
            isPinned: true
        )
        olderPinned.fingerprint = "legacy-plain-fingerprint"
        try await HistoryPersistence(storageURL: url, fixedKeyData: key).save([
            newest,
            olderPinned,
        ])

        let store = ClipboardStore(storageURL: url, fixedEncryptionKey: key)
        await waitUntilLoaded(store)

        let survivor = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(survivor.id, newest.id)
        XCTAssertEqual(survivor.payload, newest.payload)
        XCTAssertEqual(survivor.sourceAppName, "Newest App")
        XCTAssertEqual(survivor.fingerprint, newest.payload.fingerprint)
        XCTAssertTrue(survivor.isPinned)
        XCTAssertEqual(survivor.lastUsedAt, olderPinned.lastUsedAt)
        XCTAssertEqual(survivor.mostRecentDate, now)

        try await Task.sleep(for: .milliseconds(120))
        let rewritten = try await HistoryPersistence(storageURL: url, fixedKeyData: key).load()
        XCTAssertEqual(rewritten, [survivor])
    }

    func testStartupDuplicateCleanupKeepsMostRecentlyUsedRepresentation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.clops")
        let key = Data(repeating: 9, count: 32)
        let now = Date.now
        var capturedLater = ClipboardEntry(
            payload: .text(plain: "same", rtf: nil, html: nil),
            capturedAt: now,
            sourceAppName: "Later Capture"
        )
        capturedLater.fingerprint = "legacy-plain-fingerprint"
        var usedLater = ClipboardEntry(
            payload: .text(
                plain: "same",
                rtf: Data("recently used rich representation".utf8),
                html: nil
            ),
            capturedAt: now.addingTimeInterval(-10),
            lastUsedAt: now.addingTimeInterval(5),
            sourceAppName: "Recently Used"
        )
        usedLater.fingerprint = "legacy-rich-fingerprint"
        try await HistoryPersistence(storageURL: url, fixedKeyData: key).save([
            capturedLater,
            usedLater,
        ])

        let store = ClipboardStore(storageURL: url, fixedEncryptionKey: key)
        await waitUntilLoaded(store)

        let survivor = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(survivor.id, usedLater.id)
        XCTAssertEqual(survivor.payload, usedLater.payload)
        XCTAssertEqual(survivor.sourceAppName, "Recently Used")
        XCTAssertEqual(survivor.lastUsedAt, usedLater.lastUsedAt)
        XCTAssertEqual(survivor.fingerprint, usedLater.payload.fingerprint)
    }

    func testLegacyPlaintextIsReencryptedImmediatelyAfterLoad() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.clops")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = ClipboardEntry(payload: .text(plain: "legacy-secret", rtf: nil, html: nil))
        try JSONEncoder().encode([entry]).write(to: url)

        let store = ClipboardStore(
            storageURL: url,
            fixedEncryptionKey: Data(repeating: 6, count: 32)
        )
        await waitUntilLoaded(store)
        try await Task.sleep(for: .milliseconds(120))

        let data = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("legacy-secret"))
        XCTAssertTrue(data.starts(with: Data("CLOPS-HISTORY-1\n".utf8)))
    }

    func testCorruptHistoryCanBeResetInApp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.clops")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not valid history".utf8).write(to: url)
        let key = Data(repeating: 8, count: 32)
        let store = ClipboardStore(storageURL: url, fixedEncryptionKey: key)
        await waitUntilLoaded(store)
        XCTAssertEqual(
            store.persistenceError,
            HistoryPersistenceError.invalidEncryptedFile.localizedDescription
        )
        XCTAssertFalse(store.persistenceError?.contains("DecodingError") == true)

        await store.resetPersistence()

        XCTAssertNil(store.persistenceError)
        XCTAssertTrue(store.entries.isEmpty)
        let loaded = try await HistoryPersistence(storageURL: url, fixedKeyData: key).load()
        XCTAssertEqual(loaded, [])
    }

    func testWrongHistoryKeyReportsFriendlyErrorWithoutOverwritingFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.clops")
        let originalKey = Data(repeating: 0x11, count: 32)
        let wrongKey = Data(repeating: 0x22, count: 32)
        let entry = ClipboardEntry(
            payload: .text(plain: "preserve me", rtf: nil, html: nil)
        )
        let originalPersistence = HistoryPersistence(
            storageURL: url,
            fixedKeyData: originalKey
        )
        try await originalPersistence.save([entry])
        let encryptedBytes = try Data(contentsOf: url)

        await assertInvalidEncryptedHistory(
            HistoryPersistence(storageURL: url, fixedKeyData: wrongKey)
        )

        XCTAssertEqual(try Data(contentsOf: url), encryptedBytes)
        let recovered = try await originalPersistence.load()
        XCTAssertEqual(recovered, [entry])
    }

    func testHistoryRetryPreservesKeyMismatchedFileUntilExplicitReset() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.clops")
        let originalKey = Data(repeating: 0x61, count: 32)
        let currentKey = Data(repeating: 0x62, count: 32)
        let original = ClipboardEntry(
            payload: .text(plain: "old encrypted history", rtf: nil, html: nil)
        )
        try await HistoryPersistence(
            storageURL: url,
            fixedKeyData: originalKey
        ).save([original])
        let originalBytes = try Data(contentsOf: url)

        let store = ClipboardStore(storageURL: url, fixedEncryptionKey: currentKey)
        await waitUntilLoaded(store)
        XCTAssertEqual(
            store.persistenceError,
            HistoryPersistenceError.invalidEncryptedFile.localizedDescription
        )

        await store.retryPersistence()

        XCTAssertEqual(
            store.persistenceError,
            HistoryPersistenceError.invalidEncryptedFile.localizedDescription
        )
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)

        XCTAssertNotNil(store.capture(
            .text(plain: "kept only in memory", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        ))
        guard case .failure = await store.flushPersistence() else {
            return XCTFail("Unavailable encrypted storage must not overwrite the old file")
        }
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)

        await store.resetPersistence()

        XCTAssertNil(store.persistenceError)
        XCTAssertTrue(store.entries.isEmpty)
        let resetHistory = try await HistoryPersistence(
            storageURL: url,
            fixedKeyData: currentKey
        ).load()
        XCTAssertEqual(resetHistory, [])
    }

    func testTamperedHistoryReportsFriendlyErrorWithoutOverwritingFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.clops")
        let key = Data(repeating: 0x33, count: 32)
        let persistence = HistoryPersistence(storageURL: url, fixedKeyData: key)
        try await persistence.save([
            ClipboardEntry(payload: .text(plain: "authenticated", rtf: nil, html: nil))
        ])
        var tamperedBytes = try Data(contentsOf: url)
        tamperedBytes[tamperedBytes.index(before: tamperedBytes.endIndex)] ^= 0x01
        try tamperedBytes.write(to: url)

        await assertInvalidEncryptedHistory(persistence)

        XCTAssertEqual(try Data(contentsOf: url), tamperedBytes)
    }

    func testTruncatedEncryptedEnvelopeReportsFriendlyError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.clops")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var truncated = Data("CLOPS-HISTORY-1\n".utf8)
        truncated.append(Data(repeating: 0x44, count: 12))
        try truncated.write(to: url)

        await assertInvalidEncryptedHistory(
            HistoryPersistence(storageURL: url, fixedKeyData: Data(repeating: 0x44, count: 32))
        )
    }

    func testAuthenticatedInvalidJSONReportsFriendlyError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.clops")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keyData = Data(repeating: 0x55, count: 32)
        let sealedBox = try AES.GCM.seal(
            Data("authenticated but not history JSON".utf8),
            using: SymmetricKey(data: keyData)
        )
        var fileData = Data("CLOPS-HISTORY-1\n".utf8)
        fileData.append(try XCTUnwrap(sealedBox.combined))
        try fileData.write(to: url)

        await assertInvalidEncryptedHistory(
            HistoryPersistence(storageURL: url, fixedKeyData: keyData)
        )
    }

    func testResetBlocksMutationsAndQuitFlushUntilStoreIsCleared() async throws {
        let persistence = GatedHistoryPersistence()
        let store = ClipboardStore(persistence: persistence)
        await waitUntilLoaded(store)
        let original = try XCTUnwrap(store.capture(
            .text(plain: "before reset", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        ))
        guard case .success = await store.flushPersistence() else {
            return XCTFail("Initial history flush failed")
        }

        let resetTask = Task { @MainActor in
            await store.resetPersistence()
        }
        await persistence.waitUntilResetStarted()
        XCTAssertTrue(store.isResettingPersistence)

        let rejectedDuringReset = store.capture(
            .text(plain: "during reset", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        )
        XCTAssertNil(rejectedDuringReset)
        XCTAssertEqual(store.entries.map(\.id), [original.id])

        // Model applicationShouldTerminate arriving while resetFile is still
        // suspended. Its explicit flush must wait and snapshot the empty
        // post-reset store, not enqueue this pre-reset entry behind reset.
        store.prepareForTermination()
        let quitFlushTask = Task { @MainActor in
            await store.flushPersistence()
        }
        for _ in 0..<10 { await Task.yield() }
        let operationsWhileResetIsBlocked = await persistence.recordedOperations()
        XCTAssertEqual(operationsWhileResetIsBlocked, [.save(["before reset"])])

        await persistence.finishReset()
        await resetTask.value
        XCTAssertFalse(store.isResettingPersistence)
        guard case .success = await quitFlushTask.value else {
            return XCTFail("Quit flush failed")
        }

        let completedOperations = await persistence.recordedOperations()
        XCTAssertEqual(
            completedOperations,
            [.save(["before reset"]), .reset, .save([])]
        )
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.capture(
            .text(plain: "still terminating", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        ))

        store.resumeAfterCancelledTermination()
        XCTAssertNotNil(store.capture(
            .text(plain: "resumed", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        ))
    }

    func testFailedResetRestoresMutationAcceptance() async throws {
        let persistence = GatedHistoryPersistence(resetFails: true)
        let store = ClipboardStore(persistence: persistence)
        await waitUntilLoaded(store)

        let resetTask = Task { @MainActor in
            await store.resetPersistence()
        }
        await persistence.waitUntilResetStarted()
        XCTAssertTrue(store.isResettingPersistence)
        XCTAssertNil(store.capture(
            .text(plain: "blocked", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        ))

        await persistence.finishReset()
        await resetTask.value

        XCTAssertFalse(store.isResettingPersistence)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertNotNil(store.capture(
            .text(plain: "accepted after failure", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        ))
    }

    func testResetStartingAfterTerminationFreezeIsIgnored() async throws {
        let persistence = GatedHistoryPersistence(gatesReset: false)
        let store = ClipboardStore(persistence: persistence)
        await waitUntilLoaded(store)
        let original = try XCTUnwrap(store.capture(
            .text(plain: "preserve while quitting", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        ))
        guard case .success = await store.flushPersistence() else {
            return XCTFail("Initial history flush failed")
        }

        store.prepareForTermination()
        await store.resetPersistence()

        XCTAssertEqual(store.entries.map(\.id), [original.id])
        let operations = await persistence.recordedOperations()
        XCTAssertEqual(operations, [.save(["preserve while quitting"])])
    }

    func testPersistenceEncryptsHistoryAtRest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.clops")
        let persistence = HistoryPersistence(
            storageURL: url,
            fixedKeyData: Data(repeating: 9, count: 32)
        )
        let entry = ClipboardEntry(payload: .text(plain: "super-secret-value", rtf: nil, html: nil))

        try await persistence.save([entry])

        let rawData = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: rawData, as: UTF8.self).contains("super-secret-value"))
        let loaded = try await persistence.load()
        XCTAssertEqual(loaded, [entry])
    }

    func testFirstLoadCreatesEncryptedEmptyHistoryImmediately() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.clops")
        let key = Data(repeating: 4, count: 32)

        let result = try await HistoryPersistence(
            storageURL: url,
            fixedKeyData: key
        ).loadResult()

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertFalse(result.requiresEncryptedRewrite)
        let rawData = try Data(contentsOf: url)
        XCTAssertTrue(rawData.starts(with: Data("CLOPS-HISTORY-1\n".utf8)))
        let loaded = try await HistoryPersistence(
            storageURL: url,
            fixedKeyData: key
        ).load()
        XCTAssertEqual(loaded, [])
    }

    func testLoadingExistingHistoryDoesNotRewriteIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.clops")
        let key = Data(repeating: 5, count: 32)
        let persistence = HistoryPersistence(storageURL: url, fixedKeyData: key)
        let entry = ClipboardEntry(payload: .text(plain: "keep me", rtf: nil, html: nil))
        try await persistence.save([entry])
        let originalData = try Data(contentsOf: url)

        let loaded = try await persistence.load()

        XCTAssertEqual(loaded, [entry])
        XCTAssertEqual(try Data(contentsOf: url), originalData)
    }

    func testMissingKeychainEntitlementErrorExplainsSigningRepair() {
        let message = HistoryPersistenceError.keychain(-34_018).localizedDescription

        XCTAssertTrue(message.contains("Keychain Sharing"))
        XCTAssertTrue(message.contains("Development Team"))
        XCTAssertTrue(message.contains("Signing & Capabilities"))
    }

    func testMissingEncryptionKeyErrorExplainsNonDestructiveRecovery() {
        let message = HistoryPersistenceError.missingEncryptionKey.localizedDescription

        XCTAssertTrue(message.contains("Keychain key"))
        XCTAssertTrue(message.contains("has not been overwritten"))
        XCTAssertTrue(message.contains("Development Team"))
        XCTAssertTrue(message.contains("reset history storage"))
        XCTAssertTrue(message.contains("permanently deletes"))
    }

    func testFailedLoadCannotBeOverwrittenByDirectSave() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.clops")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let originalData = Data("not valid history".utf8)
        try originalData.write(to: url)
        let persistence = HistoryPersistence(storageURL: url)

        do {
            _ = try await persistence.load()
            XCTFail("Expected the invalid history load to fail")
        } catch HistoryPersistenceError.invalidEncryptedFile {
            // Expected.
        }

        do {
            try await persistence.save([])
            XCTFail("Expected save to remain blocked after a failed load")
        } catch HistoryPersistenceError.historyNotLoaded {
            // Expected.
        }

        XCTAssertEqual(try Data(contentsOf: url), originalData)
    }

    func testHistoryKeychainQueryAlwaysSelectsDataProtectionKeychain() {
        let query = KeychainHistoryKey.dataProtectionQuery(service: "test.history")

        XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, true)
    }

    func testHostedTestProcessIsRecognizedBeforeAppStartup() {
        XCTAssertTrue(AppDelegate.isUnitTestHost())
    }

    func testUnitTestHostDetectionDoesNotMatchNormalLaunch() {
        XCTAssertFalse(
            AppDelegate.isUnitTestHost(environment: [:], hasXCTestRuntime: false)
        )
        XCTAssertTrue(
            AppDelegate.isUnitTestHost(
                environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
                hasXCTestRuntime: false
            )
        )
    }

    func testOversizedHistoryIsRejectedBeforeLoading() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.clops")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 49 * 1_024 * 1_024)
        try file.close()

        do {
            _ = try await HistoryPersistence(
                storageURL: url,
                fixedKeyData: Data(repeating: 2, count: 32)
            ).load()
            XCTFail("Expected an oversized history error")
        } catch HistoryPersistenceError.historyTooLarge {
            // Expected.
        }
    }

    func testResetReusesExistingEncryptionKey() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.clops")
        let key = Data(repeating: 5, count: 32)
        let persistence = HistoryPersistence(storageURL: url, fixedKeyData: key)
        try await persistence.save([
            ClipboardEntry(payload: .text(plain: "remove me", rtf: nil, html: nil))
        ])

        try await persistence.resetFile()
        let loaded = try await persistence.load()

        XCTAssertEqual(loaded, [])
    }

    private func makeStore(maxItems: Int = 20) -> ClipboardStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return ClipboardStore(
            storageURL: directory.appendingPathComponent("history.json"),
            maxHistoryItems: maxItems,
            retentionDays: 30,
            fixedEncryptionKey: Data(repeating: 7, count: 32)
        )
    }

    private func makeBudgetStore(encodedBytes: Int) -> ClipboardStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return ClipboardStore(
            storageURL: directory.appendingPathComponent("history.clops"),
            fixedEncryptionKey: Data(repeating: 7, count: 32),
            maxStorageBytes: 100_000,
            maxEncodedStorageBytes: encodedBytes
        )
    }

    private func waitUntilLoaded(_ store: ClipboardStore) async {
        for _ in 0..<100 {
            if !store.isLoading { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Clipboard store did not finish loading")
    }

    private func assertInvalidEncryptedHistory(
        _ persistence: HistoryPersistence,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await persistence.load()
            XCTFail("Expected invalid encrypted history", file: file, line: line)
        } catch HistoryPersistenceError.invalidEncryptedFile {
            XCTAssertFalse(
                HistoryPersistenceError.invalidEncryptedFile.localizedDescription
                    .contains("CryptoKit"),
                file: file,
                line: line
            )
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private actor GatedHistoryPersistence: HistoryPersisting {
    enum Operation: Equatable, Sendable {
        case save([String])
        case reset
    }

    private enum ResetFailure: Error {
        case requested
    }

    private let resetFails: Bool
    private let gatesReset: Bool
    private var operations: [Operation] = []
    private var resetStarted = false
    private var resetStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var resetGate: CheckedContinuation<Void, Never>?

    init(resetFails: Bool = false, gatesReset: Bool = true) {
        self.resetFails = resetFails
        self.gatesReset = gatesReset
    }

    func loadResult() async throws -> HistoryLoadResult {
        HistoryLoadResult(entries: [], requiresEncryptedRewrite: false)
    }

    func save(_ entries: [ClipboardEntry]) async throws {
        operations.append(.save(entries.map(\.payload.title)))
    }

    func resetFile() async throws {
        resetStarted = true
        let waiters = resetStartWaiters
        resetStartWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume() }

        if gatesReset {
            await withCheckedContinuation { continuation in
                resetGate = continuation
            }
        }
        operations.append(.reset)
        if resetFails { throw ResetFailure.requested }
    }

    func waitUntilResetStarted() async {
        guard !resetStarted else { return }
        await withCheckedContinuation { continuation in
            resetStartWaiters.append(continuation)
        }
    }

    func finishReset() {
        let continuation = resetGate
        resetGate = nil
        continuation?.resume()
    }

    func recordedOperations() -> [Operation] {
        operations
    }
}

private actor LoadFailingHistoryPersistence: HistoryPersisting {
    private struct LoadFailure: LocalizedError {
        var errorDescription: String? { "History storage could not be opened." }
    }

    func loadResult() async throws -> HistoryLoadResult {
        throw LoadFailure()
    }

    func save(_ entries: [ClipboardEntry]) async throws {
        throw LoadFailure()
    }

    func resetFile() async throws {
        throw LoadFailure()
    }
}
