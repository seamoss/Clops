import AppKit
import Combine
import XCTest
@testable import Clops

@MainActor
final class ClipboardMonitorTests: XCTestCase {
    func testDisabledCaptureIsNotRequestedForEverySystemBehavior() {
        let behaviors: [NSPasteboard.AccessBehavior] = [
            .default,
            .ask,
            .alwaysAllow,
            .alwaysDeny,
        ]

        for behavior in behaviors {
            XCTAssertEqual(
                ClipboardMonitor.state(for: behavior, captureEnabled: false),
                .notRequested
            )
        }
    }

    func testDefaultBehaviorRemainsUnresolved() {
        XCTAssertEqual(
            ClipboardMonitor.state(for: .default, captureEnabled: true),
            .needsPermission
        )
    }

    func testEnabledCaptureReflectsExplicitSystemDecision() {
        XCTAssertEqual(
            ClipboardMonitor.state(for: .ask, captureEnabled: true),
            .needsAlwaysAllow
        )
        XCTAssertEqual(
            ClipboardMonitor.state(for: .alwaysAllow, captureEnabled: true),
            .allowed
        )
        XCTAssertEqual(
            ClipboardMonitor.state(for: .alwaysDeny, captureEnabled: true),
            .denied
        )
    }

    func testPollPublishesOncePerAcceptedPasteboardChange() {
        var uptime = 10.0
        let context = makeMonitor(uptimeProvider: { uptime })
        defer { context.monitor.stop() }
        var activities: [ClipboardActivity] = []
        let activity = context.monitor.copyActivityPublisher.sink {
            activities.append($0)
        }

        context.monitor.start()
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.setString("A fresh copy", forType: .string))
        context.monitor.poll()
        context.monitor.poll()

        XCTAssertEqual(activities.map(\.kind), [.inserted])
        XCTAssertEqual(activities.map(\.burstCount), [1])
        XCTAssertEqual(context.store.entries.map(\.payload.title), ["A fresh copy"])

        uptime += 0.2
        writeRichText("A fresh copy", to: context.pasteboard)
        context.monitor.poll()

        XCTAssertEqual(activities.map(\.kind), [.inserted, .resurfaced])
        XCTAssertEqual(activities.map(\.burstCount), [1, 2])
        XCTAssertEqual(activities[0].entryID, activities[1].entryID)
        XCTAssertEqual(context.store.entries.count, 1)
        guard case let .text(_, rtf, html) = context.store.entries[0].payload else {
            return XCTFail("Expected refreshed text payload")
        }
        XCTAssertNotNil(rtf)
        XCTAssertNotNil(html)
        withExtendedLifetime(activity) {}
    }

    func testPollDoesNotPublishForRejectedCopy() {
        let context = makeMonitor(maxStorageBytes: 1)
        defer { context.monitor.stop() }
        var activityCount = 0
        let activity = context.monitor.copyActivityPublisher.sink { _ in
            activityCount += 1
        }

        context.monitor.start()
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.setString("too large", forType: .string))
        context.monitor.poll()

        XCTAssertEqual(activityCount, 0)
        XCTAssertTrue(context.store.entries.isEmpty)
        withExtendedLifetime(activity) {}
    }

    func testPollDoesNotPublishWhilePaused() {
        let context = makeMonitor()
        defer { context.monitor.stop() }
        var activityCount = 0
        let activity = context.monitor.copyActivityPublisher.sink { _ in
            activityCount += 1
        }

        context.monitor.start()
        context.monitor.togglePaused()
        context.pasteboard.clearContents()
        XCTAssertTrue(context.pasteboard.setString("paused copy", forType: .string))
        context.monitor.poll()

        XCTAssertEqual(activityCount, 0)
        XCTAssertTrue(context.store.entries.isEmpty)
        withExtendedLifetime(activity) {}
    }

    func testPollDoesNotReadOrPublishWithoutAlwaysAllow() {
        let behaviors: [NSPasteboard.AccessBehavior] = [.default, .ask, .alwaysDeny]

        for behavior in behaviors {
            let context = makeMonitor(accessBehavior: behavior)
            var activityCount = 0
            let activity = context.monitor.copyActivityPublisher.sink { _ in
                activityCount += 1
            }

            context.monitor.start()
            context.pasteboard.clearContents()
            XCTAssertTrue(context.pasteboard.setString("private copy", forType: .string))
            context.monitor.poll()
            context.monitor.stop()

            XCTAssertEqual(activityCount, 0, "Unexpected activity for \(behavior)")
            XCTAssertTrue(context.store.entries.isEmpty)
            withExtendedLifetime(activity) {}
        }
    }

    func testCopyingAHistoryEntryPublishesActivity() throws {
        var uptime = 20.0
        let context = makeMonitor(uptimeProvider: { uptime })
        let entry = try XCTUnwrap(context.store.capture(
            .text(plain: "copy me", rtf: nil, html: nil),
            sourceAppName: nil,
            sourceBundleIdentifier: nil
        ))
        var activities: [ClipboardActivity] = []
        let activity = context.monitor.copyActivityPublisher.sink {
            activities.append($0)
        }

        XCTAssertNotNil(context.monitor.copy(entry))
        uptime += 0.1
        XCTAssertNotNil(context.monitor.copy(entry))

        XCTAssertEqual(activities.map(\.kind), [.copiedFromHistory, .copiedFromHistory])
        XCTAssertEqual(activities.map(\.burstCount), [1, 2])
        XCTAssertEqual(context.pasteboard.string(forType: .string), "copy me")
        withExtendedLifetime(activity) {}
    }

    func testBurstCountResetsForDifferentContentAndAfterTimeout() {
        var uptime = 30.0
        let context = makeMonitor(uptimeProvider: { uptime }, copyBurstInterval: 0.9)
        defer { context.monitor.stop() }
        var activities: [ClipboardActivity] = []
        let activity = context.monitor.copyActivityPublisher.sink {
            activities.append($0)
        }

        context.monitor.start()
        write("A", to: context.pasteboard)
        context.monitor.poll()
        uptime += 0.2
        write("A", to: context.pasteboard)
        context.monitor.poll()
        uptime += 0.2
        write("B", to: context.pasteboard)
        context.monitor.poll()
        uptime += 1.0
        write("B", to: context.pasteboard)
        context.monitor.poll()

        XCTAssertEqual(activities.map(\.burstCount), [1, 2, 1, 1])
        XCTAssertEqual(activities.map(\.kind), [.inserted, .resurfaced, .inserted, .resurfaced])
        XCTAssertEqual(context.store.entries.map(\.payload.title), ["B", "A"])
        withExtendedLifetime(activity) {}
    }

    func testMultiplePasteboardChangesBeforePollAreReportedAsOneBurst() {
        let context = makeMonitor()
        defer { context.monitor.stop() }
        var activities: [ClipboardActivity] = []
        let activity = context.monitor.copyActivityPublisher.sink {
            activities.append($0)
        }

        context.monitor.start()
        write("same", to: context.pasteboard)
        write("same", to: context.pasteboard)
        write("same", to: context.pasteboard)
        context.monitor.poll()

        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities.first?.burstCount, 3)
        XCTAssertEqual(context.store.entries.count, 1)
        withExtendedLifetime(activity) {}
    }

    func testRejectedChangeBreaksAnObservedCopyBurst() {
        var uptime = 40.0
        let context = makeMonitor(
            maxStorageBytes: 2,
            uptimeProvider: { uptime }
        )
        defer { context.monitor.stop() }
        var activities: [ClipboardActivity] = []
        let activity = context.monitor.copyActivityPublisher.sink {
            activities.append($0)
        }

        context.monitor.start()
        write("A", to: context.pasteboard)
        context.monitor.poll()
        uptime += 0.2
        write("rejected", to: context.pasteboard)
        context.monitor.poll()
        uptime += 0.2
        write("A", to: context.pasteboard)
        context.monitor.poll()

        XCTAssertEqual(activities.map(\.kind), [.inserted, .resurfaced])
        XCTAssertEqual(activities.map(\.burstCount), [1, 1])
        XCTAssertEqual(context.store.entries.map(\.payload.title), ["A"])
        withExtendedLifetime(activity) {}
    }

    func testObservedChangeCountIsClampedAndHandlesRegression() {
        XCTAssertEqual(ClipboardMonitor.observedChangeOccurrences(from: 10, to: 13), 3)
        XCTAssertEqual(ClipboardMonitor.observedChangeOccurrences(from: 10, to: 100), 8)
        XCTAssertEqual(ClipboardMonitor.observedChangeOccurrences(from: 10, to: 9), 1)
        XCTAssertEqual(
            ClipboardMonitor.observedChangeOccurrences(from: Int.min, to: Int.max),
            1
        )
    }

    private func makeMonitor(
        maxStorageBytes: Int = 32 * 1_024 * 1_024,
        accessBehavior: NSPasteboard.AccessBehavior = .alwaysAllow,
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        copyBurstInterval: TimeInterval = 0.9
    ) -> (monitor: ClipboardMonitor, pasteboard: NSPasteboard, store: ClipboardStore) {
        let defaults = UserDefaults(suiteName: "ClipboardMonitorTests.\(UUID().uuidString)")!
        let preferences = AppPreferences(
            defaults: defaults,
            launchAtLoginService: TestLaunchAtLoginService()
        )
        preferences.backgroundCaptureEnabled = true

        let storageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("history.clops")
        let store = ClipboardStore(
            storageURL: storageURL,
            fixedEncryptionKey: Data(repeating: 4, count: 32),
            maxStorageBytes: maxStorageBytes
        )
        let pasteboard = NSPasteboard.withUniqueName()
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            store: store,
            preferences: preferences,
            accessBehaviorProvider: { accessBehavior },
            uptimeProvider: uptimeProvider,
            copyBurstInterval: copyBurstInterval
        )
        return (monitor, pasteboard, store)
    }

    private func write(_ value: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(value, forType: .string))
    }

    private func writeRichText(_ value: String, to pasteboard: NSPasteboard) {
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        item.setData(Data("{\\rtf1 \(value)}".utf8), forType: .rtf)
        item.setData(Data("<b>\(value)</b>".utf8), forType: .html)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
    }
}
