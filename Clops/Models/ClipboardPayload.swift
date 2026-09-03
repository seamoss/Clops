import AppKit
import CryptoKit
import Foundation

enum ClipboardContentKind: String, Codable, Sendable {
    case text
    case image
    case files

    var label: String {
        switch self {
        case .text: "Text"
        case .image: "Image"
        case .files: "Files"
        }
    }

    var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }
}

struct ClipboardFileReference: Codable, Equatable, Sendable {
    let url: URL
    let bookmarkData: Data?

    private enum ResolutionError: Error {
        case missingBookmark
        case invalidFileURL
        case securityScopeUnavailable
    }

    init(url: URL, bookmarkData: Data? = nil) {
        self.url = url.standardizedFileURL
        self.bookmarkData = bookmarkData
    }

    static func capture(_ url: URL) -> ClipboardFileReference? {
        guard url.isFileURL else { return nil }

        // Keep the pasteboard-provided URL instance while creating the
        // bookmark: URL transformations can discard its sandbox extension.
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return nil }
        return ClipboardFileReference(url: url, bookmarkData: bookmark)
    }

    /// Resolves and opens the stored security scope. The caller must balance a
    /// successful result with `stopAccessingSecurityScopedResource()`.
    fileprivate func resolveForWriting() throws -> (url: URL, reference: ClipboardFileReference) {
        guard let bookmarkData else { throw ResolutionError.missingBookmark }
        var isStale = false
        let scopedURL = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard scopedURL.isFileURL else { throw ResolutionError.invalidFileURL }
        guard scopedURL.startAccessingSecurityScopedResource() else {
            throw ResolutionError.securityScopeUnavailable
        }

        do {
            let resolvedBookmark: Data
            if isStale {
                resolvedBookmark = try scopedURL.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } else {
                resolvedBookmark = bookmarkData
            }
            return (
                scopedURL,
                ClipboardFileReference(url: scopedURL, bookmarkData: resolvedBookmark)
            )
        } catch {
            scopedURL.stopAccessingSecurityScopedResource()
            throw error
        }
    }
}

enum ClipboardPayload: Codable, Equatable, Sendable {
    case text(plain: String, rtf: Data?, html: Data?)
    case image(data: Data, typeIdentifier: String)
    case files([ClipboardFileReference])

    private enum CodingKeys: String, CodingKey {
        case kind
        case plain
        case rtf
        case html
        case data
        case typeIdentifier
        case urls
    }

    var kind: ClipboardContentKind {
        switch self {
        case .text: .text
        case .image: .image
        case .files: .files
        }
    }

    var title: String {
        switch self {
        case let .text(plain, _, _):
            let collapsed = plain
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.isEmpty ? "Empty text" : collapsed
        case .image:
            return "Image"
        case let .files(references):
            guard references.count != 1 else { return references[0].url.lastPathComponent }
            return "\(references.count) files"
        }
    }

    var plainText: String? {
        switch self {
        case let .text(plain, _, _): plain
        case let .files(references): references.map(\.url.path).joined(separator: "\n")
        case .image: nil
        }
    }

    var searchableText: String {
        switch self {
        case let .text(plain, _, _): plain
        case let .files(references):
            references.flatMap { [$0.url.lastPathComponent, $0.url.path] }.joined(separator: " ")
        case .image: "image photo picture"
        }
    }

    var byteCount: Int {
        switch self {
        case let .text(plain, rtf, html):
            plain.utf8.count + (rtf?.count ?? 0) + (html?.count ?? 0)
        case let .image(data, typeIdentifier):
            data.count + typeIdentifier.utf8.count
        case let .files(references):
            references.reduce(0) {
                $0 + $1.url.absoluteString.utf8.count + ($1.bookmarkData?.count ?? 0)
            }
        }
    }

    var fingerprint: String {
        var source = Data()

        func append(_ tag: String, _ data: Data) {
            let tagData = Data(tag.utf8)
            var tagLength = UInt32(tagData.count).bigEndian
            var dataLength = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &tagLength) { source.append(contentsOf: $0) }
            source.append(tagData)
            withUnsafeBytes(of: &dataLength) { source.append(contentsOf: $0) }
            source.append(data)
        }

        append("kind", Data(kind.rawValue.utf8))
        switch self {
        case let .text(plain, _, _):
            // Plain text is the stable identity users see in history. RTF and
            // HTML often contain volatile producer metadata, so hashing those
            // representations creates duplicate rows after repeated Copy
            // commands. The newest payload still replaces the stored one,
            // preserving its latest formatting for paste.
            append("plain", Data(plain.utf8))
        case let .image(data, typeIdentifier):
            append("image-type", Data(typeIdentifier.utf8))
            append("image-data", data)
        case let .files(references):
            for reference in references {
                append("file-url", Data(reference.url.standardizedFileURL.absoluteString.utf8))
            }
        }
        return SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(ClipboardContentKind.self, forKey: .kind)
        switch kind {
        case .text:
            self = .text(
                plain: try container.decode(String.self, forKey: .plain),
                rtf: try container.decodeIfPresent(Data.self, forKey: .rtf),
                html: try container.decodeIfPresent(Data.self, forKey: .html)
            )
        case .image:
            self = .image(
                data: try container.decode(Data.self, forKey: .data),
                typeIdentifier: try container.decode(String.self, forKey: .typeIdentifier)
            )
        case .files:
            if let references = try? container.decode([ClipboardFileReference].self, forKey: .urls) {
                self = .files(references)
            } else {
                let legacyURLs = try container.decode([URL].self, forKey: .urls)
                self = .files(legacyURLs.map { ClipboardFileReference(url: $0) })
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case let .text(plain, rtf, html):
            try container.encode(plain, forKey: .plain)
            try container.encodeIfPresent(rtf, forKey: .rtf)
            try container.encodeIfPresent(html, forKey: .html)
        case let .image(data, typeIdentifier):
            try container.encode(data, forKey: .data)
            try container.encode(typeIdentifier, forKey: .typeIdentifier)
        case let .files(references):
            try container.encode(references, forKey: .urls)
        }
    }
}

extension ClipboardPayload {
    @MainActor
    mutating func write(to pasteboard: NSPasteboard) -> Bool {
        switch self {
        case let .text(plain, rtf, html):
            let item = NSPasteboardItem()
            item.setString(plain, forType: .string)
            if let rtf { item.setData(rtf, forType: .rtf) }
            if let html { item.setData(html, forType: .html) }
            pasteboard.clearContents()
            return pasteboard.writeObjects([item])

        case let .image(data, typeIdentifier):
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(typeIdentifier))
            pasteboard.clearContents()
            return pasteboard.writeObjects([item])

        case let .files(references):
            guard !references.isEmpty else { return false }

            var resolved: [(url: URL, reference: ClipboardFileReference)] = []
            do {
                for reference in references {
                    resolved.append(try reference.resolveForWriting())
                }
            } catch {
                resolved.forEach { $0.url.stopAccessingSecurityScopedResource() }
                return false
            }
            defer { resolved.forEach { $0.url.stopAccessingSecurityScopedResource() } }

            pasteboard.clearContents()
            guard pasteboard.writeObjects(resolved.map(\.url) as [NSURL]) else { return false }
            self = .files(resolved.map(\.reference))
            return true
        }
    }
}
