import Foundation

struct ClipboardEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var payload: ClipboardPayload
    var fingerprint: String
    var capturedAt: Date
    var lastUsedAt: Date?
    var sourceAppName: String?
    var sourceBundleIdentifier: String?
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        payload: ClipboardPayload,
        capturedAt: Date = .now,
        lastUsedAt: Date? = nil,
        sourceAppName: String? = nil,
        sourceBundleIdentifier: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.payload = payload
        self.fingerprint = payload.fingerprint
        self.capturedAt = capturedAt
        self.lastUsedAt = lastUsedAt
        self.sourceAppName = sourceAppName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.isPinned = isPinned
    }

    var mostRecentDate: Date {
        max(capturedAt, lastUsedAt ?? .distantPast)
    }
}
