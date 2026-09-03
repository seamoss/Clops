import AppKit
import Combine
import Foundation

enum ClipboardAccessState: Equatable {
    case notRequested
    case needsPermission
    case needsAlwaysAllow
    case allowed
    case denied
}

enum ClipboardActivityKind: Equatable {
    case inserted
    case resurfaced
    case copiedFromHistory
}

struct ClipboardActivity: Equatable {
    let entryID: ClipboardEntry.ID
    let kind: ClipboardActivityKind
    /// Best-effort count of pasteboard ownership changes in the current
    /// same-content burst. macOS can coalesce intermediate clipboard states,
    /// so this is feedback metadata rather than an authoritative keypress count.
    let burstCount: Int
}

@MainActor
final class ClipboardMonitor: ObservableObject {
    private static let maximumObservedBurstIncrement = 8

    @Published var isPaused = false
    @Published private(set) var accessState: ClipboardAccessState

    /// Fires after Clops successfully captures or writes clipboard content.
    /// This is intentionally an event rather than store observation: loading,
    /// pinning, deleting, and clearing history should not look like copy activity.
    var copyActivityPublisher: AnyPublisher<ClipboardActivity, Never> {
        copyActivitySubject.eraseToAnyPublisher()
    }

    private struct CopyBurst {
        let fingerprint: String
        let sourceBundleIdentifier: String?
        let observedAt: TimeInterval
        let count: Int
    }

    private let pasteboard: NSPasteboard
    private let store: ClipboardStore
    private let preferences: AppPreferences
    private let accessBehaviorProvider: () -> NSPasteboard.AccessBehavior
    private let uptimeProvider: () -> TimeInterval
    private let copyBurstInterval: TimeInterval
    private let copyActivitySubject = PassthroughSubject<ClipboardActivity, Never>()
    private var lastObservedChangeCount: Int
    private var pollingTask: Task<Void, Never>?
    private var isRunning = false
    private var activeApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var lastCopyBurst: CopyBurst?

    init(
        pasteboard: NSPasteboard = .general,
        store: ClipboardStore,
        preferences: AppPreferences,
        accessBehaviorProvider: (() -> NSPasteboard.AccessBehavior)? = nil,
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        copyBurstInterval: TimeInterval = 0.9
    ) {
        self.pasteboard = pasteboard
        self.store = store
        self.preferences = preferences
        self.accessBehaviorProvider = accessBehaviorProvider ?? { pasteboard.accessBehavior }
        self.uptimeProvider = uptimeProvider
        self.copyBurstInterval = max(copyBurstInterval, 0)
        self.lastObservedChangeCount = pasteboard.changeCount
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        self.activeApplication = frontmostApplication
        if frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            self.lastExternalApplication = frontmostApplication
        }
        self.accessState = Self.state(
            for: self.accessBehaviorProvider(),
            captureEnabled: preferences.backgroundCaptureEnabled
        )
    }

    func start() {
        guard pollingTask == nil else { return }
        isRunning = true
        lastObservedChangeCount = pasteboard.changeCount
        pollingTask = Task { @MainActor [weak self] in
            var ticksUntilMaintenance = 12_000
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.poll()
                ticksUntilMaintenance -= 1
                if ticksUntilMaintenance == 0 {
                    self.store.performMaintenance()
                    ticksUntilMaintenance = 12_000
                }
            }
        }
    }

    func stop() {
        isRunning = false
        pollingTask?.cancel()
        pollingTask = nil
        lastCopyBurst = nil
    }

    func togglePaused() {
        isPaused.toggle()
        lastObservedChangeCount = pasteboard.changeCount
        lastCopyBurst = nil
    }

    func requestClipboardAccess() {
        preferences.backgroundCaptureEnabled = true

        // Pasteboard access is deliberate here: this method is called only from
        // an Enable/Continue button after Clops has explained why it needs access.
        // Reading the current contents gives macOS an immediate opportunity to
        // show its Paste from Other Apps decision instead of failing silently in
        // the background.
        let source = sourceApplicationForCurrentPasteboard()
        let payload = PasteboardReader.read(
            from: pasteboard,
            captureImages: preferences.captureImages,
            captureFiles: preferences.captureFiles
        )
        lastObservedChangeCount = pasteboard.changeCount
        refreshAccessState()

        guard !isPaused, let payload, !isExcluded(source) else {
            lastCopyBurst = nil
            return
        }
        capture(payload, sourceApplication: source)
    }

    func disableClipboardAccess() {
        preferences.backgroundCaptureEnabled = false
        lastObservedChangeCount = pasteboard.changeCount
        lastCopyBurst = nil
        refreshAccessState()
    }

    func applicationDidActivate(_ application: NSRunningApplication) {
        // If the pasteboard changed between timer ticks, attribute that copy to
        // the app that was active before this transition rather than the newly
        // activated app.
        if isRunning {
            poll(sourceApplication: activeApplication)
        }
        activeApplication = application
        if application.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApplication = application
        }
    }

    func refreshAccessState() {
        accessState = Self.state(
            for: accessBehaviorProvider(),
            captureEnabled: preferences.backgroundCaptureEnabled
        )
    }

    @discardableResult
    func copy(_ entry: ClipboardEntry, plainTextOnly: Bool = false) -> Int? {
        var payload: ClipboardPayload
        if plainTextOnly, let text = entry.payload.plainText {
            payload = .text(plain: text, rtf: nil, html: nil)
        } else {
            payload = entry.payload
        }

        let previousChangeCount = pasteboard.changeCount
        guard payload.write(to: pasteboard) else { return nil }
        let writtenChangeCount = pasteboard.changeCount
        lastObservedChangeCount = writtenChangeCount
        let resurfacedEntry = store.markUsed(
            entry.id,
            refreshedPayload: plainTextOnly ? nil : payload
        )
        publishCopyActivity(
            entryID: resurfacedEntry?.id ?? entry.id,
            kind: .copiedFromHistory,
            payload: payload,
            sourceBundleIdentifier: "__clops_history__",
            observedOccurrences: Self.observedChangeOccurrences(
                from: previousChangeCount,
                to: writtenChangeCount
            )
        )
        return writtenChangeCount
    }

    func poll(sourceApplication: NSRunningApplication? = nil) {
        guard isRunning else { return }
        let currentChangeCount = pasteboard.changeCount
        refreshAccessState()
        guard currentChangeCount != lastObservedChangeCount else { return }
        let observedOccurrences = Self.observedChangeOccurrences(
            from: lastObservedChangeCount,
            to: currentChangeCount
        )
        lastObservedChangeCount = currentChangeCount
        guard !isPaused, preferences.backgroundCaptureEnabled else {
            lastCopyBurst = nil
            return
        }

        let behavior = accessBehaviorProvider()
        // Never let the timer itself trigger a privacy alert. Until the user
        // chooses Always Allow, another read must come from an explicit
        // Enable/Continue gesture so its purpose and timing stay clear.
        guard behavior == .alwaysAllow else {
            lastCopyBurst = nil
            return
        }

        let source = sourceApplication ?? activeApplication ?? NSWorkspace.shared.frontmostApplication
        guard !isExcluded(source) else {
            lastCopyBurst = nil
            return
        }

        guard let payload = PasteboardReader.read(
            from: pasteboard,
            captureImages: preferences.captureImages,
            captureFiles: preferences.captureFiles
        ) else {
            lastCopyBurst = nil
            return
        }

        refreshAccessState()
        capture(
            payload,
            sourceApplication: source,
            observedOccurrences: observedOccurrences
        )
    }

    var currentChangeCount: Int { pasteboard.changeCount }

    static func state(
        for behavior: NSPasteboard.AccessBehavior,
        captureEnabled: Bool
    ) -> ClipboardAccessState {
        guard captureEnabled else { return .notRequested }
        switch behavior {
        case .default:
            // The default behavior is an unresolved privacy decision. It must
            // never be promoted to Allowed based on a previous successful read.
            return .needsPermission
        case .ask:
            return .needsAlwaysAllow
        case .alwaysAllow:
            return .allowed
        case .alwaysDeny:
            return .denied
        @unknown default:
            return .denied
        }
    }

    static func observedChangeOccurrences(from previous: Int, to current: Int) -> Int {
        // Multiple Copy commands can land between 300 ms polls. changeCount is
        // the only permission-free signal for that activity; clamp it because
        // some producers perform several ownership changes for one command.
        let (difference, overflowed) = current.subtractingReportingOverflow(previous)
        guard !overflowed, difference > 0 else { return 1 }
        return min(difference, maximumObservedBurstIncrement)
    }

    private func sourceApplicationForCurrentPasteboard() -> NSRunningApplication? {
        if activeApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            return activeApplication
        }
        return lastExternalApplication
    }

    private func isExcluded(_ application: NSRunningApplication?) -> Bool {
        guard let bundleIdentifier = application?.bundleIdentifier else { return false }
        return preferences.excludedBundleIdentifiers.contains(bundleIdentifier)
    }

    @discardableResult
    private func capture(
        _ payload: ClipboardPayload,
        sourceApplication source: NSRunningApplication?,
        observedOccurrences: Int = 1
    ) -> Bool {
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let sourceIsClops = source?.bundleIdentifier == ownBundleIdentifier
        guard let outcome = store.captureWithOutcome(
            payload,
            sourceAppName: sourceIsClops ? nil : source?.localizedName,
            sourceBundleIdentifier: sourceIsClops ? nil : source?.bundleIdentifier
        ) else {
            lastCopyBurst = nil
            return false
        }

        let kind: ClipboardActivityKind = switch outcome.disposition {
        case .inserted: .inserted
        case .resurfaced: .resurfaced
        }
        publishCopyActivity(
            entryID: outcome.entry.id,
            kind: kind,
            payload: payload,
            sourceBundleIdentifier: sourceIsClops ? nil : source?.bundleIdentifier,
            observedOccurrences: observedOccurrences
        )
        return true
    }

    private func publishCopyActivity(
        entryID: ClipboardEntry.ID,
        kind: ClipboardActivityKind,
        payload: ClipboardPayload,
        sourceBundleIdentifier: String?,
        observedOccurrences: Int = 1
    ) {
        let observedAt = uptimeProvider()
        let fingerprint = payload.fingerprint
        let occurrenceIncrement = min(
            max(observedOccurrences, 1),
            Self.maximumObservedBurstIncrement
        )
        let burstCount: Int
        if let lastCopyBurst,
           lastCopyBurst.fingerprint == fingerprint,
           lastCopyBurst.sourceBundleIdentifier == sourceBundleIdentifier,
           observedAt >= lastCopyBurst.observedAt,
           observedAt - lastCopyBurst.observedAt <= copyBurstInterval {
            burstCount = lastCopyBurst.count > Int.max - occurrenceIncrement
                ? Int.max
                : lastCopyBurst.count + occurrenceIncrement
        } else {
            burstCount = occurrenceIncrement
        }

        lastCopyBurst = CopyBurst(
            fingerprint: fingerprint,
            sourceBundleIdentifier: sourceBundleIdentifier,
            observedAt: observedAt,
            count: burstCount
        )
        copyActivitySubject.send(ClipboardActivity(
            entryID: entryID,
            kind: kind,
            burstCount: burstCount
        ))
    }
}
