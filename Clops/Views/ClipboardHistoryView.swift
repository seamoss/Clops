import AppKit
import SwiftUI

struct ClipboardHistoryView: View {
    private enum Scope: String, CaseIterable, Identifiable {
        case all = "All"
        case pinned = "Pinned"

        var id: Self { self }
    }

    @ObservedObject var store: ClipboardStore
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var coordinator: PasteCoordinator
    @ObservedObject var hotKey: GlobalHotKey

    @State private var searchText = ""
    @State private var scope: Scope = .all
    @State private var selectedID: ClipboardEntry.ID?
    @State private var confirmsClear = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            if monitor.accessState != .allowed {
                ClipboardAccessBanner(
                    state: monitor.accessState,
                    requestAccess: monitor.requestClipboardAccess
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }

            searchBar
                .padding(.horizontal, 12)
                .padding(.bottom, 9)

            Picker("History scope", selection: $scope) {
                ForEach(Scope.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 9)

            Divider()

            if store.isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Unlocking history…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleEntries.isEmpty {
                EmptyHistoryView(
                    hasSearch: !searchText.isEmpty,
                    pinnedOnly: scope == .pinned,
                    clearSearch: { searchText = "" }
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(visibleEntries) { entry in
                                ClipboardRowView(
                                    entry: entry,
                                    targetAppName: coordinator.targetAppName,
                                    preferredActionPastes: coordinator.willPastePreferredAction,
                                    onUse: { intent in
                                        selectedID = entry.id
                                        coordinator.use(entry, intent: intent)
                                    },
                                    onTogglePinned: { store.togglePinned(entry.id) },
                                    onDelete: {
                                        selectedID = entry.id
                                        deleteSelected()
                                    }
                                )
                                .id(entry.id)
                                .background(
                                    selectedID == entry.id ? Color.accentColor.opacity(0.10) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .padding(.horizontal, 5)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    .onChange(of: selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            Divider()
            footer
        }
        .frame(width: 390, height: 550)
        .background(.regularMaterial)
        .defaultFocus($searchFocused, true)
        .onAppear {
            selectedID = visibleEntries.first?.id
        }
        .onChange(of: visibleEntries.map(\.id)) { _, ids in
            if let selectedID {
                if !ids.contains(selectedID) {
                    self.selectedID = ids.first
                }
            } else {
                selectedID = ids.first
            }
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.command) {
                useSelected(intent: .copy)
            } else if press.modifiers.contains(.shift) {
#if MAC_APP_STORE
                useSelected(intent: .copyPlainText)
#else
                useSelected(intent: .pastePlainText)
#endif
            } else {
                useSelected(intent: .preferred)
            }
            return .handled
        }
        .onKeyPress(.escape) {
            if searchText.isEmpty {
                coordinator.close()
            } else {
                searchText = ""
            }
            return .handled
        }
        .confirmationDialog(
            "Clear unpinned history?",
            isPresented: $confirmsClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { store.clearUnpinned() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pinned items will remain.")
        }
    }

    private var visibleEntries: [ClipboardEntry] {
        store.entries.filter { entry in
            let matchesScope = scope == .all || entry.isPinned
            let matchesSearch = searchText.isEmpty
                || entry.payload.searchableText.localizedCaseInsensitiveContains(searchText)
                || entry.sourceAppName?.localizedCaseInsensitiveContains(searchText) == true
            return matchesScope && matchesSearch
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "clipboard.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Clops")
                .font(.headline)
            Spacer()

            Button {
                monitor.togglePaused()
            } label: {
                Image(systemName: monitor.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .help(monitor.isPaused ? "Resume capture" : "Pause capture")

            Menu {
                Button(monitor.isPaused ? "Resume Capture" : "Pause Capture") {
                    monitor.togglePaused()
                }
                Button("Clear Unpinned History…") { confirmsClear = true }
                    .disabled(store.entries.allSatisfy(\.isPinned))
                Divider()
                SettingsLink {
                    Label("Settings…", systemImage: "gearshape")
                }
                Divider()
                Button("Quit Clops") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(12)
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search \(store.entries.count) copies", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(spacing: 7) {
            if monitor.isPaused {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(.orange)
                Text("Capture paused")
            } else if let notice = coordinator.notice {
                Text(notice)
            } else if let notice = store.managementNotice {
                Text(notice)
            } else if store.persistenceError != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("History storage error")
                SettingsLink {
                    Text("Details")
                }
                .controlSize(.mini)
            } else if !hotKey.isRegistered {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Keyboard shortcut unavailable")
            } else if coordinator.willPastePreferredAction, let target = coordinator.targetAppName {
                Text("Return pastes into \(target)")
            } else {
                Text("Return copies · \(hotKey.activeShortcutLabel ?? "Shortcut") opens Clops")
            }
            Spacer()
            Text("↑↓")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    private func moveSelection(by offset: Int) {
        guard !visibleEntries.isEmpty else { return }
        let currentIndex = selectedID.flatMap { id in
            visibleEntries.firstIndex { $0.id == id }
        } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), visibleEntries.count - 1)
        selectedID = visibleEntries[nextIndex].id
    }

    private func useSelected(intent: ClipboardUseIntent) {
        guard let selectedID, let entry = visibleEntries.first(where: { $0.id == selectedID }) else { return }
        coordinator.use(entry, intent: intent)
    }

    private func deleteSelected() {
        guard let selectedID,
              let removedIndex = visibleEntries.firstIndex(where: { $0.id == selectedID }) else { return }
        store.delete(selectedID)
        let remaining = visibleEntries
        self.selectedID = remaining.isEmpty ? nil : remaining[min(removedIndex, remaining.count - 1)].id
    }
}
