import SwiftUI

struct EmptyHistoryView: View {
    let hasSearch: Bool
    let pinnedOnly: Bool
    let clearSearch: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            if hasSearch {
                Button("Clear Search", action: clearSearch)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var systemImage: String {
        hasSearch ? "magnifyingglass" : (pinnedOnly ? "pin" : "clipboard")
    }

    private var title: String {
        hasSearch ? "No matches" : (pinnedOnly ? "No pinned items" : "Your history is empty")
    }

    private var message: String {
        if hasSearch { return "Try a different word or clear the search." }
        if pinnedOnly { return "Pin anything you want to keep close." }
        return "Copy text, images, or files and they’ll appear here."
    }
}
