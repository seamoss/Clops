import AppKit
import SwiftUI

struct ClipboardRowView: View {
    let entry: ClipboardEntry
    let targetAppName: String?
    let preferredActionPastes: Bool
    let onUse: (ClipboardUseIntent) -> Void
    let onTogglePinned: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            onUse(.preferred)
        } label: {
            HStack(spacing: 11) {
                preview
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.payload.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 5) {
                        if let sourceAppName = entry.sourceAppName {
                            Text(sourceAppName)
                                .lineLimit(1)
                        } else {
                            Text(entry.payload.kind.label)
                        }
                        Text("·")
                        Text(entry.mostRecentDate, style: .relative)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                } else if isHovering {
                    Image(systemName: preferredActionPastes ? "return" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
#if !MAC_APP_STORE
            Button {
                onUse(.paste)
            } label: {
                Label("Paste\(targetAppName.map { " into \($0)" } ?? "")", systemImage: "return")
            }
            .disabled(targetAppName == nil)
#endif

            Button {
                onUse(.copy)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            if entry.payload.plainText != nil {
                Button {
#if MAC_APP_STORE
                    onUse(.copyPlainText)
#else
                    onUse(.pastePlainText)
#endif
                } label: {
                    Label(plainTextActionTitle, systemImage: "textformat")
                }
#if !MAC_APP_STORE
                .disabled(targetAppName == nil)
#endif
            }

            Divider()

            Button(action: onTogglePinned) {
                Label(entry.isPinned ? "Unpin" : "Pin", systemImage: entry.isPinned ? "pin.slash" : "pin")
            }

            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var plainTextActionTitle: String {
#if MAC_APP_STORE
        entry.payload.kind == .files ? "Copy File Paths as Text" : "Copy as Plain Text"
#else
        entry.payload.kind == .files ? "Paste File Paths as Text" : "Paste as Plain Text"
#endif
    }

    @ViewBuilder
    private var preview: some View {
        switch entry.payload {
        case .text:
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.secondary)
                }

        case let .image(data, _):
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                fallbackPreview(systemImage: "photo")
            }

        case let .files(references):
            fallbackPreview(systemImage: references.count > 1 ? "doc.on.doc.fill" : "doc.fill")
        }
    }

    private func fallbackPreview(systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
            }
    }
}
