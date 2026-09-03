import CryptoKit
import Foundation
@preconcurrency import Security

enum HistoryPersistenceError: LocalizedError {
    case invalidEncryptedFile
    case encryptionFailed
    case missingEncryptionKey
    case historyNotLoaded
    case historyTooLarge
    case keychain(OSStatus)
    case randomGeneration(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidEncryptedFile:
            "Clops couldn’t unlock the encrypted clipboard history. Its file may be damaged or its Keychain key may have changed. The existing file has not been overwritten. Retry first; if the error remains, reset history storage to start fresh. Reset permanently deletes the old history."
        case .encryptionFailed:
            "Clops couldn’t encrypt clipboard history. Retry history storage; if the error remains, relaunch Clops."
        case .missingEncryptionKey:
            "Clops couldn’t find the Keychain key for this encrypted history. The history file has not been overwritten. If this build uses a different Development Team, restore its original signing settings and retry. Otherwise, reset history storage to start fresh; reset permanently deletes the old history."
        case .historyNotLoaded:
            "Clipboard history must load successfully before it can be saved. The existing file has not been overwritten."
        case .historyTooLarge:
            "Clipboard history is too large to save safely. Delete some large or pinned items."
        case let .keychain(status):
            if status == errSecMissingEntitlement {
                "Encrypted history is unavailable because this build does not have a valid Keychain Sharing entitlement. In Xcode, select the Clops target, choose a Development Team under Signing & Capabilities, then rebuild and relaunch."
            } else {
                "The history encryption key could not be accessed (\(status))."
            }
        case let .randomGeneration(status):
            "A secure history encryption key could not be generated (\(status))."
        }
    }
}

struct HistoryLoadResult: Sendable {
    let entries: [ClipboardEntry]
    let requiresEncryptedRewrite: Bool
}

protocol HistoryPersisting: Sendable {
    func loadResult() async throws -> HistoryLoadResult
    func save(_ entries: [ClipboardEntry]) async throws
    func resetFile() async throws
}

actor HistoryPersistence: HistoryPersisting {
    private static let magic = Data("CLOPS-HISTORY-1\n".utf8)
    private static let maximumPlaintextBytes = 48 * 1_024 * 1_024
    private static let maximumStoredFileBytes = maximumPlaintextBytes + magic.count + 64

    private let storageURL: URL
    private let fixedKeyData: Data?
    private let keychainService: String
    private var isReadyForSaving = false

    init(storageURL: URL, fixedKeyData: Data? = nil) {
        self.storageURL = storageURL
        self.fixedKeyData = fixedKeyData
        self.keychainService = "\(Bundle.main.bundleIdentifier ?? "com.seamoss.Clops").history"
    }

    func load() throws -> [ClipboardEntry] {
        try loadResult().entries
    }

    func loadResult() throws -> HistoryLoadResult {
        isReadyForSaving = false
        let result = try readLoadResult()
        isReadyForSaving = true
        return result
    }

    private func readLoadResult() throws -> HistoryLoadResult {
        let data: Data
        do {
            let values = try storageURL.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = values.fileSize, fileSize > Self.maximumStoredFileBytes {
                throw HistoryPersistenceError.historyTooLarge
            }
            data = try Data(contentsOf: storageURL, options: .mappedIfSafe)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return try prepareEmptyHistoryIfMissing()
        }
        guard data.count <= Self.maximumStoredFileBytes else {
            throw HistoryPersistenceError.historyTooLarge
        }

        // Early development builds stored JSON. The store immediately rewrites
        // this legacy format as AES-GCM ciphertext after a successful load.
        guard data.starts(with: Self.magic) else {
            guard data.count <= Self.maximumPlaintextBytes else {
                throw HistoryPersistenceError.historyTooLarge
            }
            do {
                return HistoryLoadResult(
                    entries: try JSONDecoder().decode([ClipboardEntry].self, from: data),
                    requiresEncryptedRewrite: true
                )
            } catch {
                throw HistoryPersistenceError.invalidEncryptedFile
            }
        }

        let encrypted = data.dropFirst(Self.magic.count)
        guard !encrypted.isEmpty else { throw HistoryPersistenceError.invalidEncryptedFile }
        // Resolve the key outside the CryptoKit boundary so entitlement and
        // Keychain failures retain their actionable, specific messages.
        let key = try existingEncryptionKey()
        let plaintext: Data
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encrypted)
            plaintext = try AES.GCM.open(sealedBox, using: key)
        } catch {
            // Authentication failure cannot distinguish a changed key from
            // damaged ciphertext. In either case, preserve the file and let
            // the user choose between a non-destructive retry and reset.
            throw HistoryPersistenceError.invalidEncryptedFile
        }
        guard plaintext.count <= Self.maximumPlaintextBytes else {
            throw HistoryPersistenceError.historyTooLarge
        }
        do {
            return HistoryLoadResult(
                entries: try JSONDecoder().decode([ClipboardEntry].self, from: plaintext),
                requiresEncryptedRewrite: false
            )
        } catch {
            throw HistoryPersistenceError.invalidEncryptedFile
        }
    }

    func save(_ entries: [ClipboardEntry]) throws {
        guard !Task.isCancelled else { return }
        // The production store always loads before saving. Enforce that here
        // too so a future/direct caller cannot replace ciphertext that failed
        // authentication. A fixed key is an explicit test-only persistence seam.
        guard fixedKeyData != nil || isReadyForSaving else {
            throw HistoryPersistenceError.historyNotLoaded
        }
        try write(entries, using: try loadOrCreateEncryptionKey(), honorsCancellation: true)
        isReadyForSaving = true
    }

    func resetFile() throws {
        // Reuse the current key so reset has one durable commit: the atomic
        // empty-history write. Rotating the key first would let a process or
        // power loss strand the old file with a replacement key. If the key is
        // already missing, create one so an explicitly confirmed reset can
        // recover storage.
        try write(
            [],
            using: try loadOrCreateEncryptionKey(),
            honorsCancellation: false
        )
        isReadyForSaving = true
    }

    private func write(
        _ entries: [ClipboardEntry],
        using key: SymmetricKey,
        honorsCancellation: Bool
    ) throws {
        func shouldStop() -> Bool {
            honorsCancellation && Task.isCancelled
        }

        guard let fileData = try encryptedFileData(
            for: entries,
            using: key,
            shouldStop: shouldStop
        ) else { return }

        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // `.completeFileProtection` is not a supported macOS app capability
        // and can fail with EPERM. The payload is already protected at rest
        // with AES-GCM; keep the filesystem write atomic here.
        try fileData.write(to: storageURL, options: .atomic)
    }

    private func prepareEmptyHistoryIfMissing() throws -> HistoryLoadResult {
        let key = try loadOrCreateEncryptionKey()
        guard let fileData = try encryptedFileData(
            for: [],
            using: key,
            shouldStop: { false }
        ) else {
            throw HistoryPersistenceError.invalidEncryptedFile
        }

        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stagingURL = directory.appendingPathComponent(
            ".clops-history-\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: stagingURL) }

        // Write a complete staging inode, then publish it with an
        // exclusive same-volume link. `Data` deliberately rejects combining
        // `.atomic` and `.withoutOverwriting`; linking provides both desired
        // properties without ever exposing a partial destination file.
        try fileData.write(
            to: stagingURL,
            options: .withoutOverwriting
        )
        do {
            // Creation is exclusive so a history file that appears between
            // the initial read and this write is loaded instead of replaced.
            try FileManager.default.linkItem(at: stagingURL, to: storageURL)
            return HistoryLoadResult(entries: [], requiresEncryptedRewrite: false)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
                && error.code == CocoaError.Code.fileWriteFileExists.rawValue {
            return try readLoadResult()
        }
    }

    private func encryptedFileData(
        for entries: [ClipboardEntry],
        using key: SymmetricKey,
        shouldStop: () -> Bool
    ) throws -> Data? {
        guard !shouldStop() else { return nil }
        let plaintext = try JSONEncoder().encode(entries)
        guard plaintext.count <= Self.maximumPlaintextBytes else {
            throw HistoryPersistenceError.historyTooLarge
        }
        guard !shouldStop() else { return nil }

        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(plaintext, using: key)
        } catch {
            throw HistoryPersistenceError.encryptionFailed
        }
        guard let combined = sealedBox.combined else {
            throw HistoryPersistenceError.invalidEncryptedFile
        }

        var fileData = Self.magic
        fileData.append(combined)
        guard !shouldStop() else { return nil }
        return fileData
    }

    private func existingEncryptionKey() throws -> SymmetricKey {
        if let fixedKeyData {
            return SymmetricKey(data: fixedKeyData)
        }
        guard let keyData = try KeychainHistoryKey.load(service: keychainService) else {
            throw HistoryPersistenceError.missingEncryptionKey
        }
        return SymmetricKey(data: keyData)
    }

    private func loadOrCreateEncryptionKey() throws -> SymmetricKey {
        if let fixedKeyData {
            return SymmetricKey(data: fixedKeyData)
        }
        return SymmetricKey(data: try KeychainHistoryKey.loadOrCreate(service: keychainService))
    }
}

enum KeychainHistoryKey {
    private static let account = "history-encryption-key"

    static func load(service: String) throws -> Data? {
        try readProtected(service: service)
    }

    static func loadOrCreate(service: String) throws -> Data {
        if let existing = try load(service: service) {
            return existing
        }

        let bytes = try makeRandomKey()
        let addStatus = addProtected(bytes, service: service)
        if addStatus == errSecDuplicateItem {
            // Another caller may have installed the key after our initial
            // lookup. Prefer that key instead of replacing it.
            guard let existing = try load(service: service) else {
                throw HistoryPersistenceError.keychain(errSecItemNotFound)
            }
            return existing
        }
        guard addStatus == errSecSuccess else {
            throw HistoryPersistenceError.keychain(addStatus)
        }
        return bytes
    }

    private static func readProtected(service: String) throws -> Data? {
        var query = dataProtectionQuery(service: service)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw HistoryPersistenceError.keychain(errSecDecode)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw HistoryPersistenceError.keychain(status)
        }
    }

    private static func addProtected(_ data: Data, service: String) -> OSStatus {
        var query = dataProtectionQuery(service: service)
        query[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData] = data
        return SecItemAdd(query as CFDictionary, nil)
    }

    private static func makeRandomKey() throws -> Data {
        var bytes = Data(count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw HistoryPersistenceError.randomGeneration(randomStatus)
        }
        return bytes
    }

    static func dataProtectionQuery(service: String) -> [CFString: Any] {
        // Keep the implementation selector in the shared base so reads and
        // adds always operate in one Keychain namespace.
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
    }
}
