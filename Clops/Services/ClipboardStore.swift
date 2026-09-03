import Combine
import Foundation

private struct ClipboardPersistenceUnavailable: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ClipboardCaptureDisposition: Equatable {
    case inserted
    case resurfaced
}

struct ClipboardCaptureOutcome: Equatable {
    let entry: ClipboardEntry
    let disposition: ClipboardCaptureDisposition
}

@MainActor
final class ClipboardStore: ObservableObject {
    // HistoryPersistence rejects JSON plaintext above 48 MiB. Keep the store's
    // conservative encoded-size budget below that ceiling so a retained
    // runtime entry set is always serializable without allocating the entire
    // JSON document just to measure it on the main actor.
    private static let maximumEncodedHistoryCost = 40 * 1_024 * 1_024
    private static let entryEncodingAllowance = 4_096
    private static let fileReferenceEncodingAllowance = 512

    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var persistenceError: String?
    @Published private(set) var managementNotice: String?
    @Published private(set) var isLoading = true
    @Published private(set) var isRetryingPersistence = false
    @Published private(set) var isResettingPersistence = false

    private var maxHistoryItems: Int
    private var retentionDays: Int
    // The raw budget bounds clipboard payload memory. The encoded budget also
    // accounts for JSON string escaping, Base64 expansion, and structure.
    private let maxStorageBytes: Int
    private let maxEncodedStorageBytes: Int
    private let hardEntryLimit: Int
    private let persistence: any HistoryPersisting
    private var saveTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var hasLocalMutations = false
    private var persistenceReady = false
    private var isPreparingForTermination = false
    private var resetCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var encodedCostCache: [ClipboardEntry.ID: Int] = [:]

    private var isAcceptingMutations: Bool {
        !isPreparingForTermination && !isResettingPersistence
    }

    init(
        storageURL: URL = ClipboardStore.defaultStorageURL,
        maxHistoryItems: Int = 500,
        retentionDays: Int = 30,
        fixedEncryptionKey: Data? = nil,
        maxStorageBytes: Int = 32 * 1_024 * 1_024,
        maxEncodedStorageBytes: Int = 40 * 1_024 * 1_024,
        hardEntryLimit: Int = 2_000,
        persistence persistenceOverride: (any HistoryPersisting)? = nil
    ) {
        self.maxHistoryItems = max(maxHistoryItems, 1)
        self.retentionDays = max(retentionDays, 1)
        self.maxStorageBytes = max(maxStorageBytes, 1)
        self.maxEncodedStorageBytes = min(
            max(maxEncodedStorageBytes, 1),
            Self.maximumEncodedHistoryCost
        )
        self.hardEntryLimit = max(hardEntryLimit, 1)
        self.persistence = persistenceOverride
            ?? HistoryPersistence(storageURL: storageURL, fixedKeyData: fixedEncryptionKey)

        let persistence = self.persistence
        loadTask = Task { @MainActor [weak self] in
            do {
                let loaded = try await persistence.loadResult()
                self?.finishLoading(loaded)
            } catch {
                self?.isLoading = false
                self?.persistenceReady = false
                self?.persistenceError = error.localizedDescription
            }
        }
    }

    static var defaultStorageURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Clops", isDirectory: true)
            .appendingPathComponent("clipboard-history.clops")
    }

    func updateLimits(maxHistoryItems: Int, retentionDays: Int) {
        guard isAcceptingMutations else { return }
        self.maxHistoryItems = max(maxHistoryItems, 1)
        self.retentionDays = max(retentionDays, 1)
        hasLocalMutations = true
        trimAndPersist()
    }

    @discardableResult
    func capture(
        _ payload: ClipboardPayload,
        sourceAppName: String?,
        sourceBundleIdentifier: String?,
        at date: Date = .now
    ) -> ClipboardEntry? {
        captureWithOutcome(
            payload,
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            at: date
        )?.entry
    }

    @discardableResult
    func captureWithOutcome(
        _ payload: ClipboardPayload,
        sourceAppName: String?,
        sourceBundleIdentifier: String?,
        at date: Date = .now
    ) -> ClipboardCaptureOutcome? {
        guard isAcceptingMutations else { return nil }
        hasLocalMutations = true
        let fingerprint = payload.fingerprint
        let matches = entries.filter { $0.fingerprint == fingerprint }

        if let existing = matches.first(where: \.isPinned) ?? matches.first {
            let matchingIDs = Set(matches.map(\.id))
            var refreshed = existing
            refreshed.payload = payload
            refreshed.fingerprint = fingerprint
            refreshed.capturedAt = date
            refreshed.lastUsedAt = nil
            refreshed.sourceAppName = sourceAppName
            refreshed.sourceBundleIdentifier = sourceBundleIdentifier
            refreshed.isPinned = matches.contains(where: \.isPinned)

            // A newer rich representation or bookmark can be much larger than
            // the copy already retained under this identity. Keep and
            // resurface the safe version instead of deleting it when the
            // refresh cannot fit.
            if !canRetainEquivalentUpdate(refreshed, replacing: matchingIDs) {
                var safeResurfaced = existing
                safeResurfaced.capturedAt = date
                safeResurfaced.lastUsedAt = nil
                safeResurfaced.isPinned = matches.contains(where: \.isPinned)
                entries.removeAll { matchingIDs.contains($0.id) }
                entries.insert(safeResurfaced, at: 0)
                pruneEncodedCostCache()
                persist()
                let notice = existing.isPinned
                    ? "Pinned item kept, but its update exceeded the safety limit."
                    : "Existing item resurfaced, but its latest formatting was too large."
                showManagementNotice(notice)
                return ClipboardCaptureOutcome(entry: safeResurfaced, disposition: .resurfaced)
            }

            entries.removeAll { matchingIDs.contains($0.id) }
            encodedCostCache[refreshed.id] = Self.calculateEncodedCost(of: refreshed)
            let refreshedEncodedCost = encodedCostCache[refreshed.id] ?? .max
            entries.insert(refreshed, at: 0)
            trimAndPersist()
            guard entries.contains(where: { $0.id == refreshed.id }) else {
                showCaptureRejection(for: refreshed, encodedCost: refreshedEncodedCost)
                return nil
            }
            return ClipboardCaptureOutcome(entry: refreshed, disposition: .resurfaced)
        }

        let entry = ClipboardEntry(
            payload: payload,
            capturedAt: date,
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier
        )
        let entryEncodedCost = Self.calculateEncodedCost(of: entry)
        encodedCostCache[entry.id] = entryEncodedCost
        entries.insert(entry, at: 0)
        trimAndPersist()
        guard entries.contains(where: { $0.id == entry.id }) else {
            showCaptureRejection(for: entry, encodedCost: entryEncodedCost)
            return nil
        }
        return ClipboardCaptureOutcome(entry: entry, disposition: .inserted)
    }

    func togglePinned(_ id: ClipboardEntry.ID) {
        guard isAcceptingMutations else { return }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if !entries[index].isPinned {
            let pinnedEntries = entries.filter(\.isPinned)
            let pinnedBytes = Self.totalRawBytes(of: pinnedEntries)
            let pinnedEncodedCost = totalEncodedCost(of: pinnedEntries)
            let entryEncodedCost = encodedCost(of: entries[index])
            guard pinnedEntries.count < hardEntryLimit,
                  Self.saturatedAdd(pinnedBytes, entries[index].payload.byteCount) <= maxStorageBytes,
                  Self.saturatedAdd(pinnedEncodedCost, entryEncodedCost) <= maxEncodedStorageBytes else {
                showManagementNotice("Pinned history has reached its safety limit.")
                return
            }
        }
        hasLocalMutations = true
        entries[index].isPinned.toggle()
        trimAndPersist()
    }

    @discardableResult
    func markUsed(
        _ id: ClipboardEntry.ID,
        refreshedPayload: ClipboardPayload? = nil,
        at date: Date = .now
    ) -> ClipboardEntry? {
        guard isAcceptingMutations else { return nil }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        hasLocalMutations = true
        let existing = entries[index]
        var entry = existing
        var appliedRefresh = false
        if let refreshedPayload {
            entry.payload = refreshedPayload
            entry.fingerprint = refreshedPayload.fingerprint
            appliedRefresh = true
        }
        entry.lastUsedAt = date

        if appliedRefresh {
            let matchingIdentityEntries = entries.filter {
                $0.fingerprint == entry.fingerprint
            }
            var equivalentIDs = Set(matchingIdentityEntries.lazy.map(\.id))
            equivalentIDs.insert(id)
            entry.isPinned = entries.contains {
                equivalentIDs.contains($0.id) && $0.isPinned
            }

            guard canRetainEquivalentUpdate(entry, replacing: equivalentIDs) else {
                // When a refreshed file bookmark resolves to an identity that
                // is already in history, prefer that safe matching payload.
                // The clipboard now contains the resolved identity, so moving
                // the stale pre-resolution row to the top would be misleading.
                let safeIdentityMatch = matchingIdentityEntries.first(where: \.isPinned)
                    ?? matchingIdentityEntries.first
                var safeResurfaced = existing.fingerprint == entry.fingerprint
                    ? existing
                    : safeIdentityMatch ?? existing
                safeResurfaced.lastUsedAt = date
                if safeResurfaced.fingerprint == entry.fingerprint {
                    safeResurfaced.isPinned = entry.isPinned
                    entries.removeAll { equivalentIDs.contains($0.id) }
                    pruneEncodedCostCache()
                } else {
                    entries.remove(at: index)
                }
                entries.insert(safeResurfaced, at: 0)
                persist()
                let notice = entry.isPinned
                    ? "Pinned item kept, but its update exceeded the safety limit."
                    : "Item copied, but its refreshed file data was too large."
                showManagementNotice(notice)
                return safeResurfaced
            }

            encodedCostCache[entry.id] = Self.calculateEncodedCost(of: entry)
            entries.removeAll { equivalentIDs.contains($0.id) }
        } else {
            entries.remove(at: index)
        }
        entries.insert(entry, at: 0)
        if appliedRefresh {
            let refreshedCost = encodedCost(of: entry)
            trimAndPersist()
            if !entry.isPinned, !entries.contains(where: { $0.id == entry.id }) {
                showCaptureRejection(for: entry, encodedCost: refreshedCost)
                return nil
            }
        } else {
            persist()
        }
        return entry
    }

    func delete(_ id: ClipboardEntry.ID) {
        guard isAcceptingMutations else { return }
        hasLocalMutations = true
        entries.removeAll { $0.id == id }
        encodedCostCache.removeValue(forKey: id)
        persist()
    }

    func clearUnpinned() {
        guard isAcceptingMutations else { return }
        hasLocalMutations = true
        entries.removeAll { !$0.isPinned }
        pruneEncodedCostCache()
        persist()
    }

    func performMaintenance() {
        guard isAcceptingMutations else { return }
        let beforeTrimming = entries
        trimAndPersist(save: false)
        if entries != beforeTrimming { persist() }
    }

    @discardableResult
    func flushPersistence() async -> Result<Void, Error> {
        if isLoading {
            await loadTask?.value
        }
        while isResettingPersistence {
            await waitForResetCompletion()
        }
        guard persistenceReady else {
            // When startup storage never became available, only retained
            // in-memory entries can be lost. Preference changes are already in
            // UserDefaults, and rejected/no-op operations leave nothing to
            // discard, even though they may have touched the mutation path.
            if entries.isEmpty {
                return .success(())
            }
            let error = ClipboardPersistenceUnavailable(
                message: persistenceError ?? "History storage is not available."
            )
            return .failure(error)
        }
        saveTask?.cancel()
        do {
            try await persistence.save(entries)
            persistenceError = nil
            return .success(())
        } catch {
            persistenceError = error.localizedDescription
            return .failure(error)
        }
    }

    func prepareForTermination() {
        isPreparingForTermination = true
    }

    func resumeAfterCancelledTermination() {
        isPreparingForTermination = false
    }

    func retryPersistence() async {
        guard !isRetryingPersistence else { return }
        isRetryingPersistence = true
        defer { isRetryingPersistence = false }

        if isLoading {
            await loadTask?.value
        }
        while isResettingPersistence {
            await waitForResetCompletion()
        }
        if persistenceReady {
            _ = await flushPersistence()
            return
        }

        isLoading = true
        do {
            let loaded = try await persistence.loadResult()
            finishLoading(loaded)
            _ = await flushPersistence()
        } catch {
            isLoading = false
            persistenceReady = false
            persistenceError = error.localizedDescription
        }
    }

    func resetPersistence() async {
        // A reset requested by a task that did not begin running until after
        // quit preparation must not mutate storage underneath the termination
        // flush. A reset already in progress is handled by flush's barrier.
        guard !isPreparingForTermination else { return }
        if isResettingPersistence {
            await waitForResetCompletion()
            return
        }

        // Reset is a mutation barrier in its own right. Keep termination as a
        // separate reason so completing a reset cannot accidentally resume a
        // clipboard monitor that was frozen while the app was quitting.
        isResettingPersistence = true
        defer { finishResetOperation() }

        if isLoading {
            await loadTask?.value
        }
        saveTask?.cancel()
        do {
            try await persistence.resetFile()
            // A task that had already passed its debounce may still be
            // unwinding after cancellation. Invalidate it again after the
            // reset actor call before exposing the empty store.
            saveTask?.cancel()
            saveTask = nil
            entries = []
            encodedCostCache.removeAll(keepingCapacity: false)
            hasLocalMutations = false
            persistenceReady = true
            persistenceError = nil
            managementNotice = nil
        } catch {
            saveTask?.cancel()
            saveTask = nil
            persistenceError = error.localizedDescription
        }
    }

    private func waitForResetCompletion() async {
        guard isResettingPersistence else { return }
        await withCheckedContinuation { continuation in
            resetCompletionWaiters.append(continuation)
        }
    }

    private func finishResetOperation() {
        isResettingPersistence = false
        let waiters = resetCompletionWaiters
        resetCompletionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func finishLoading(_ result: HistoryLoadResult) {
        encodedCostCache.removeAll(keepingCapacity: true)
        let normalizedHistory = Self.normalizeLoadedEntries(result.entries)
        let loaded = normalizedHistory.entries
        let persistedPinsByID = Dictionary(
            uniqueKeysWithValues: loaded.lazy.filter(\.isPinned).map { ($0.id, $0) }
        )
        if hasLocalMutations {
            var loadedByFingerprint: [String: ClipboardEntry] = [:]
            for entry in loaded where loadedByFingerprint[entry.fingerprint] == nil {
                loadedByFingerprint[entry.fingerprint] = entry
            }
            var merged: [ClipboardEntry] = entries.map { local in
                guard var persisted = loadedByFingerprint.removeValue(forKey: local.fingerprint) else {
                    return local
                }

                let localIsNewer = local.capturedAt >= persisted.capturedAt
                persisted.payload = local.payload
                persisted.fingerprint = local.fingerprint
                persisted.capturedAt = max(local.capturedAt, persisted.capturedAt)
                persisted.lastUsedAt = [local.lastUsedAt, persisted.lastUsedAt].compactMap { $0 }.max()
                persisted.isPinned = local.isPinned || persisted.isPinned
                if localIsNewer {
                    persisted.sourceAppName = local.sourceAppName
                    persisted.sourceBundleIdentifier = local.sourceBundleIdentifier
                }
                return persisted
            }
            var appendedFingerprints: Set<String> = []
            merged.append(contentsOf: loaded.filter {
                loadedByFingerprint[$0.fingerprint] != nil
                    && appendedFingerprints.insert($0.fingerprint).inserted
            })
            entries = merged
            reconcilePinsAfterLoading(persistedPinsByID)
        } else {
            entries = loaded
        }
        persistenceReady = true
        isLoading = false
        let beforeTrimming = entries
        trimAndPersist(save: false)
        if hasLocalMutations
            || result.requiresEncryptedRewrite
            || normalizedHistory.didChange
            || entries != beforeTrimming {
            persist()
        }
    }

    private static func normalizeLoadedEntries(
        _ loaded: [ClipboardEntry]
    ) -> (entries: [ClipboardEntry], didChange: Bool) {
        var normalized: [ClipboardEntry] = []
        var indexByFingerprint: [String: Int] = [:]
        var didChange = false

        for original in loaded {
            var entry = original
            let currentFingerprint = entry.payload.fingerprint
            if entry.fingerprint != currentFingerprint {
                entry.fingerprint = currentFingerprint
                didChange = true
            }

            guard let existingIndex = indexByFingerprint[currentFingerprint] else {
                indexByFingerprint[currentFingerprint] = normalized.count
                normalized.append(entry)
                continue
            }

            didChange = true
            let existing = normalized[existingIndex]
            var survivor = entry.mostRecentDate > existing.mostRecentDate ? entry : existing
            survivor.isPinned = existing.isPinned || entry.isPinned
            survivor.lastUsedAt = [existing.lastUsedAt, entry.lastUsedAt]
                .compactMap { $0 }
                .max()
            normalized[existingIndex] = survivor
        }

        return (normalized, didChange)
    }

    private func trimAndPersist(save: Bool = true) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: .now) ?? .distantPast
        entries.removeAll { !$0.isPinned && $0.mostRecentDate < cutoff }

        var unpinnedCount = 0
        entries = entries.filter { entry in
            if entry.isPinned { return true }
            defer { unpinnedCount += 1 }
            return unpinnedCount < maxHistoryItems
        }

        let pinnedCount = entries.count(where: \.isPinned)
        var remainingUnpinnedSlots = max(hardEntryLimit - pinnedCount, 0)
        entries = entries.filter { entry in
            if entry.isPinned { return true }
            guard remainingUnpinnedSlots > 0 else { return false }
            remainingUnpinnedSlots -= 1
            return true
        }

        let pinnedBytes = Self.totalRawBytes(of: entries.lazy.filter(\.isPinned))
        var remainingBytes = max(maxStorageBytes - pinnedBytes, 0)
        entries = entries.filter { entry in
            if entry.isPinned { return true }
            guard entry.payload.byteCount <= remainingBytes else { return false }
            remainingBytes -= entry.payload.byteCount
            return true
        }

        let pinnedEntries = entries.filter(\.isPinned)
        let pinnedEncodedCost = totalEncodedCost(of: pinnedEntries)
        var remainingEncodedCost = max(maxEncodedStorageBytes - pinnedEncodedCost, 0)
        entries = entries.filter { entry in
            if entry.isPinned { return true }
            let entryEncodedCost = encodedCost(of: entry)
            guard entryEncodedCost <= remainingEncodedCost else { return false }
            remainingEncodedCost -= entryEncodedCost
            return true
        }

        if pinnedCount > hardEntryLimit
            || pinnedBytes > maxStorageBytes
            || pinnedEncodedCost > maxEncodedStorageBytes {
            showManagementNotice("Pinned items exceed the current history safety limit.")
        }

        pruneEncodedCostCache()

        if save { persist() }
    }

    private func persist() {
        guard !isLoading, persistenceReady, !isResettingPersistence else { return }
        let snapshot = entries
        let persistence = self.persistence
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                try await persistence.save(snapshot)
                guard !Task.isCancelled else { return }
                self?.persistenceError = nil
            } catch is CancellationError {
                return
            } catch {
                self?.persistenceError = error.localizedDescription
            }
        }
    }

    private func showManagementNotice(_ value: String) {
        managementNotice = value
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard self?.managementNotice == value else { return }
            self?.managementNotice = nil
        }
    }

    private func showCaptureRejection(for entry: ClipboardEntry, encodedCost: Int) {
        if entry.payload.byteCount > maxStorageBytes
            || encodedCost > maxEncodedStorageBytes {
            showManagementNotice("Not saved — this clipboard item is too large.")
        } else {
            showManagementNotice("Not saved — pinned history is full.")
        }
    }

    private func canRetainPinned(
        _ candidate: ClipboardEntry,
        replacing replacedIDs: Set<ClipboardEntry.ID>
    ) -> Bool {
        let otherPinned = entries.filter {
            $0.isPinned && !replacedIDs.contains($0.id)
        }
        guard otherPinned.count < hardEntryLimit else { return false }

        let candidateEncodedCost = Self.calculateEncodedCost(of: candidate)
        return Self.saturatedAdd(
            Self.totalRawBytes(of: otherPinned),
            candidate.payload.byteCount
        ) <= maxStorageBytes
            && Self.saturatedAdd(
                totalEncodedCost(of: otherPinned),
                candidateEncodedCost
            ) <= maxEncodedStorageBytes
    }

    private func canRetainEquivalentUpdate(
        _ candidate: ClipboardEntry,
        replacing replacedIDs: Set<ClipboardEntry.ID>
    ) -> Bool {
        if candidate.isPinned {
            return canRetainPinned(candidate, replacing: replacedIDs)
        }

        let otherPinned = entries.filter {
            $0.isPinned && !replacedIDs.contains($0.id)
        }
        guard otherPinned.count < hardEntryLimit else { return false }

        let candidateEncodedCost = Self.calculateEncodedCost(of: candidate)
        return Self.saturatedAdd(
            Self.totalRawBytes(of: otherPinned),
            candidate.payload.byteCount
        ) <= maxStorageBytes
            && Self.saturatedAdd(
                totalEncodedCost(of: otherPinned),
                candidateEncodedCost
            ) <= maxEncodedStorageBytes
    }

    /// Entries loaded as pinned are known to have fit the file that was just
    /// decoded, even if today's more conservative estimate is above the
    /// runtime budget. Startup-local changes may update those entries or add
    /// pins before loading finishes; accept the combined candidates only when
    /// they fit, otherwise restore persisted pins exactly and demote only the
    /// not-yet-persisted pin requests.
    private func reconcilePinsAfterLoading(
        _ persistedPinsByID: [ClipboardEntry.ID: ClipboardEntry]
    ) {
        let candidatePins = entries.filter(\.isPinned)
        let candidatesFit = candidatePins.count <= hardEntryLimit
            && Self.totalRawBytes(of: candidatePins) <= maxStorageBytes
            && totalEncodedCost(of: candidatePins) <= maxEncodedStorageBytes
        guard !candidatesFit else { return }

        var didRejectUpdate = false
        for index in entries.indices {
            guard let persisted = persistedPinsByID[entries[index].id] else { continue }
            if entries[index] != persisted { didRejectUpdate = true }
            entries[index] = persisted
            encodedCostCache[persisted.id] = nil
        }

        let restoredPins = entries.filter {
            $0.isPinned && persistedPinsByID[$0.id] != nil
        }
        var pinnedCount = restoredPins.count
        var pinnedBytes = Self.totalRawBytes(of: restoredPins)
        var pinnedEncodedCost = totalEncodedCost(of: restoredPins)

        for index in entries.indices where entries[index].isPinned
            && persistedPinsByID[entries[index].id] == nil {
            let entryBytes = entries[index].payload.byteCount
            let entryEncodedCost = encodedCost(of: entries[index])
            let canKeepPin = pinnedCount < hardEntryLimit
                && Self.saturatedAdd(pinnedBytes, entryBytes) <= maxStorageBytes
                && Self.saturatedAdd(pinnedEncodedCost, entryEncodedCost) <= maxEncodedStorageBytes
            if canKeepPin {
                pinnedCount += 1
                pinnedBytes = Self.saturatedAdd(pinnedBytes, entryBytes)
                pinnedEncodedCost = Self.saturatedAdd(pinnedEncodedCost, entryEncodedCost)
            } else {
                entries[index].isPinned = false
                didRejectUpdate = true
            }
        }

        if didRejectUpdate {
            showManagementNotice("Some startup pin updates exceeded the history safety limit.")
        }
    }

    private func encodedCost(of entry: ClipboardEntry) -> Int {
        if let cached = encodedCostCache[entry.id] { return cached }
        let cost = Self.calculateEncodedCost(of: entry)
        encodedCostCache[entry.id] = cost
        return cost
    }

    private func totalEncodedCost<S: Sequence>(of entries: S) -> Int
    where S.Element == ClipboardEntry {
        var result = 0
        for entry in entries {
            result = Self.saturatedAdd(result, encodedCost(of: entry))
        }
        return result
    }

    private func pruneEncodedCostCache() {
        let retainedIDs = Set(entries.lazy.map(\.id))
        encodedCostCache = encodedCostCache.filter { retainedIDs.contains($0.key) }
    }

    /// A no-allocation upper bound for this entry's JSON representation.
    /// Foundation emits UTF-8 directly except for JSON control/delimiter
    /// escapes, while Data uses Base64. Large fixed allowances cover every
    /// current key, scalar value, delimiter, UUID, date, and array separator;
    /// each file reference gets its own allowance as that array is unbounded.
    private static func calculateEncodedCost(of entry: ClipboardEntry) -> Int {
        var cost = entryEncodingAllowance
        cost = saturatedAdd(cost, jsonStringContentCost(entry.fingerprint))
        if let sourceAppName = entry.sourceAppName {
            cost = saturatedAdd(cost, jsonStringContentCost(sourceAppName))
        }
        if let sourceBundleIdentifier = entry.sourceBundleIdentifier {
            cost = saturatedAdd(cost, jsonStringContentCost(sourceBundleIdentifier))
        }

        switch entry.payload {
        case let .text(plain, rtf, html):
            cost = saturatedAdd(cost, jsonStringContentCost(plain))
            if let rtf { cost = saturatedAdd(cost, base64ContentCost(rtf.count)) }
            if let html { cost = saturatedAdd(cost, base64ContentCost(html.count)) }

        case let .image(data, typeIdentifier):
            cost = saturatedAdd(cost, base64ContentCost(data.count))
            cost = saturatedAdd(cost, jsonStringContentCost(typeIdentifier))

        case let .files(references):
            for reference in references {
                cost = saturatedAdd(cost, fileReferenceEncodingAllowance)
                cost = saturatedAdd(
                    cost,
                    jsonStringContentCost(reference.url.absoluteString)
                )
                if let bookmarkData = reference.bookmarkData {
                    cost = saturatedAdd(cost, base64ContentCost(bookmarkData.count))
                }
            }
        }
        return cost
    }

    private static func totalRawBytes<S: Sequence>(of entries: S) -> Int
    where S.Element == ClipboardEntry {
        entries.reduce(0) { saturatedAdd($0, $1.payload.byteCount) }
    }

    private static func jsonStringContentCost(_ value: String) -> Int {
        value.utf8.reduce(0) { result, byte in
            let byteCost: Int
            switch byte {
            case 0x08, 0x09, 0x0A, 0x0C, 0x0D:
                byteCost = 2
            case 0x00...0x1F:
                byteCost = 6
            case 0x22, 0x2F, 0x5C:
                byteCost = 2
            case 0x7F:
                byteCost = 6
            case 0x80...0xFF:
                // At three bytes of budget per UTF-8 byte, this also covers
                // an encoder choosing \uXXXX (or a surrogate pair) instead.
                byteCost = 3
            default:
                byteCost = 1
            }
            return saturatedAdd(result, byteCost)
        }
    }

    private static func base64ContentCost(_ byteCount: Int) -> Int {
        let completeGroups = byteCount / 3
        let remainderCost = byteCount.isMultiple(of: 3) ? 0 : 4
        let base64Cost = saturatedAdd(saturatedMultiply(completeGroups, 4), remainderCost)
        // JSONEncoder escapes '/' by default, and every Base64 character can
        // be '/' for adversarial bytes (for example, repeating 0xFF).
        return saturatedMultiply(base64Cost, 2)
    }

    private static func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }

    private static func saturatedMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? .max : result
    }
}
