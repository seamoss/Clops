import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private static let privacyPolicyURL = URL(
        string: "https://github.com/seamoss/Clops/blob/main/PRIVACY.md"
    )!

    private enum Tab: Hashable {
        case general
        case historyAndPrivacy
    }

    @ObservedObject var preferences: AppPreferences
    @ObservedObject var store: ClipboardStore
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var coordinator: PasteCoordinator
    @ObservedObject var hotKey: GlobalHotKey

    @State private var confirmsClear = false
    @State private var confirmsStorageReset = false
    @State private var selectedTab: Tab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Section {
                    LabeledContent("Open Clops at login") {
                        HStack(spacing: 10) {
                            SettingsStatusLabel(status: launchAtLoginStatus)
                            if showsLaunchAtLoginSwitch {
                                Toggle("", isOn: launchAtLoginBinding)
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .accessibilityLabel("Open Clops at login")
                            }
                        }
                    }

                    if let message = launchAtLoginMessage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.text)
                                .font(.caption)
                                .foregroundStyle(message.color)
                            launchAtLoginRecoveryControl
                        }
                    }

                    if !preferences.isRunningFromApplicationsDirectory {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("For reliable startup, move a signed Clops build to Applications and launch that copy. Xcode’s DerivedData copy can move when you rebuild.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Show Running Copy in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                            }
                            .controlSize(.small)
                        }
                    }

#if !MAC_APP_STORE
                    Toggle("Paste when choosing an item", isOn: $preferences.pasteOnSelection)
#endif

                    LabeledContent("Global shortcut") {
                        HStack(spacing: 8) {
                            SettingsStatusLabel(status: globalShortcutStatus)
                            if let shortcut = hotKey.activeShortcutLabel {
                                Text(shortcut)
                                    .font(.body.monospaced())
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }
                    if hotKey.isUsingFallback {
                        Text("\(GlobalHotKey.primaryShortcutLabel) is already in use, so Clops is using \(GlobalHotKey.fallbackShortcutLabel).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = hotKey.registrationError {
                        HStack {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Spacer()
                            Button("Retry") { hotKey.register() }
                                .controlSize(.small)
                        }
                    }
                }

#if !MAC_APP_STORE
                Section("Paste automation") {
                    LabeledContent("Accessibility access") {
                        SettingsStatusLabel(status: pasteAutomationStatus)
                    }

                    if !coordinator.pasteAccessGranted {
                        Button("Enable One-Step Paste") {
                            coordinator.requestPasteAccess()
                        }
                        .controlSize(.small)
                        Text("Clops uses this permission only to send ⌘V to the app you were using. Without it, Clops copies the item and tells you to press ⌘V.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
#endif
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(Tab.general)

            Form {
                Section("Clipboard access") {
                    Toggle("Background capture", isOn: backgroundCaptureBinding)

                    LabeledContent("Capture status") {
                        SettingsStatusLabel(status: clipboardCaptureStatus)
                    }
                    if monitor.accessState == .allowed,
                       monitor.isPaused,
                       preferences.backgroundCaptureEnabled {
                        Button("Resume Capture") {
                            monitor.togglePaused()
                        }
                        .controlSize(.small)
                    } else if monitor.accessState == .needsPermission {
                        Button("Continue Clipboard Setup") {
                            monitor.requestClipboardAccess()
                        }
                        .controlSize(.small)
                    } else if monitor.accessState == .needsAlwaysAllow {
                        Button("Open Clipboard Privacy Settings") { openClipboardSettings() }
                            .controlSize(.small)
                    } else if monitor.accessState == .denied {
                        Button("Open Clipboard Privacy Settings") { openClipboardSettings() }
                            .controlSize(.small)
                    }
                    Text(accessGuidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Clops skips clipboard items marked concealed, confidential, or transient. Some source apps may not label sensitive content correctly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("History") {
                    LabeledContent("Storage") {
                        HStack(spacing: 6) {
                            if isHistoryStorageBusy {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            SettingsStatusLabel(status: historyStorageStatus)
                        }
                    }
                    Picker("Maximum unpinned items", selection: $preferences.maxHistoryItems) {
                        ForEach([100, 250, 500, 1_000], id: \.self) { count in
                            Text(count.formatted()).tag(count)
                        }
                    }
                    Picker("Keep unpinned items", selection: $preferences.retentionDays) {
                        Text("1 day").tag(1)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    Toggle("Capture images", isOn: $preferences.captureImages)
                    Toggle("Capture files", isOn: $preferences.captureFiles)
                }

                Section("Excluded applications") {
                    if preferences.excludedBundleIdentifiers.isEmpty {
                        Text("No applications excluded")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(preferences.excludedBundleIdentifiers.sorted(), id: \.self) { bundleIdentifier in
                            HStack {
                                Text(bundleIdentifier)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    preferences.removeExcludedApplication(bundleIdentifier: bundleIdentifier)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove exclusion")
                            }
                        }
                    }
                    Button("Exclude Application…") { chooseExcludedApplication() }
                }

                Section {
                    Button("Clear Unpinned History…", role: .destructive) {
                        confirmsClear = true
                    }
                    .disabled(store.entries.allSatisfy(\.isPinned))
                }

                Section {
                    Text("All history is stored locally in Application Support. Clops has no account, analytics, network access, or cloud sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link(destination: Self.privacyPolicyURL) {
                        Label("Privacy Policy", systemImage: "arrow.up.right.square")
                    }
                }

                if let persistenceError = store.persistenceError {
                    Section("History storage error") {
                        Text(persistenceError)
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button("Retry History Storage") {
                            Task { await store.retryPersistence() }
                        }
                        .disabled(isHistoryStorageBusy)
                        Button("Reset History Storage…", role: .destructive) {
                            confirmsStorageReset = true
                        }
                        .disabled(isHistoryStorageBusy)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("History & Privacy", systemImage: "hand.raised") }
            .tag(Tab.historyAndPrivacy)
        }
        .frame(width: 500, height: 430)
        .onAppear {
            if store.persistenceError != nil {
                selectedTab = .historyAndPrivacy
            }
            monitor.refreshAccessState()
            coordinator.refreshPasteAccessStatus()
            preferences.refreshLaunchAtLoginStatus()
        }
        .onChange(of: store.persistenceError) { _, error in
            if error != nil {
                selectedTab = .historyAndPrivacy
            }
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
        .confirmationDialog(
            "Reset history storage?",
            isPresented: $confirmsStorageReset,
            titleVisibility: .visible
        ) {
            Button("Delete All History and Reset", role: .destructive) {
                Task { await store.resetPersistence() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all clipboard history, including pinned items, and creates fresh encrypted storage.")
        }
    }

    private var accessGuidance: String {
        if monitor.accessState == .allowed,
           monitor.isPaused,
           preferences.backgroundCaptureEnabled {
            return "Background capture is paused. Resume it when you want Clops to watch for new copies again."
        }

        return switch monitor.accessState {
        case .notRequested:
            "Turn on Background capture when you are ready. Clops will then make a deliberate clipboard read so macOS can ask for permission."
        case .needsPermission:
            "Copy something if the clipboard is empty, then continue setup. Allow that read, then choose Always Allow under Privacy & Security → Paste from Other Apps."
        case .needsAlwaysAllow:
            "Clops is currently set to Ask. Choose Always Allow under Privacy & Security → Paste from Other Apps for background history."
        case .allowed:
            "Clops can read new copies in the background. macOS may require a quit and reopen after a privacy-setting change."
        case .denied:
            "In System Settings, go to Privacy & Security → Paste from Other Apps and choose Always Allow for Clops."
        }
    }

    private var backgroundCaptureBinding: Binding<Bool> {
        Binding(
            get: { preferences.backgroundCaptureEnabled },
            set: { enabled in
                if enabled {
                    monitor.requestClipboardAccess()
                } else {
                    monitor.disableClipboardAccess()
                }
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { preferences.launchAtLoginEnabled },
            set: { preferences.setLaunchAtLoginEnabled($0) }
        )
    }

    private var showsLaunchAtLoginSwitch: Bool {
        guard !preferences.launchAtLoginNeedsRepair else { return false }
        return preferences.launchAtLoginState == .disabled
            || preferences.launchAtLoginState == .enabled
    }

    private var launchAtLoginMessage: SettingsMessage? {
        if let error = preferences.launchAtLoginError {
            return SettingsMessage(text: error, color: .red)
        }

        return switch preferences.launchAtLoginState {
        case .disabled, .enabled:
            nil
        case .needsApproval:
            SettingsMessage(
                text: "Clops is registered, but macOS requires approval in General → Login Items & Extensions.",
                color: Color(nsColor: .secondaryLabelColor)
            )
        case .unavailable:
            SettingsMessage(
                text: "macOS couldn’t read the login-item status. Retry after relaunching Clops.",
                color: Color(nsColor: .secondaryLabelColor)
            )
        }
    }

    @ViewBuilder
    private var launchAtLoginRecoveryControl: some View {
        if preferences.launchAtLoginNeedsRepair {
            Button("Repair") {
                preferences.repairLaunchAtLoginRegistration()
            }
            .controlSize(.small)
        } else if preferences.launchAtLoginState == .needsApproval {
            Button("Open Login Items") {
                preferences.openLaunchAtLoginSettings()
            }
            .controlSize(.small)
        } else if preferences.launchAtLoginState == .unavailable {
            Button("Retry") {
                preferences.retryLaunchAtLoginStatus()
            }
            .controlSize(.small)
        }
    }

    private var launchAtLoginStatus: SettingsStatus {
        if preferences.launchAtLoginNeedsRepair {
            return SettingsStatus(
                title: "Needs repair",
                systemImage: "wrench.and.screwdriver.fill",
                color: .orange
            )
        }

        return switch preferences.launchAtLoginState {
        case .disabled:
            SettingsStatus(
                title: "Disabled",
                systemImage: "circle",
                color: Color(nsColor: .secondaryLabelColor)
            )
        case .enabled:
            SettingsStatus(
                title: "Enabled",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        case .needsApproval:
            SettingsStatus(
                title: "Approval required",
                systemImage: "exclamationmark.triangle.fill",
                color: .orange
            )
        case .unavailable:
            SettingsStatus(
                title: "Unavailable",
                systemImage: "questionmark.circle.fill",
                color: .red
            )
        }
    }

    private var globalShortcutStatus: SettingsStatus {
        if hotKey.isRegistered, hotKey.isUsingFallback {
            return SettingsStatus(
                title: "Fallback active",
                systemImage: "exclamationmark.circle.fill",
                color: .orange
            )
        }
        if hotKey.isRegistered {
            return SettingsStatus(
                title: "Active",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        }
        return SettingsStatus(
            title: "Unavailable",
            systemImage: "xmark.circle.fill",
            color: .red
        )
    }

#if !MAC_APP_STORE
    private var pasteAutomationStatus: SettingsStatus {
        if coordinator.pasteAccessGranted {
            return SettingsStatus(
                title: "Allowed",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        }
        return SettingsStatus(
            title: "Access required",
            systemImage: "exclamationmark.circle.fill",
            color: .orange
        )
    }
#endif

    private var clipboardCaptureStatus: SettingsStatus {
        guard preferences.backgroundCaptureEnabled else {
            return SettingsStatus(
                title: "Off",
                systemImage: "circle",
                color: Color(nsColor: .secondaryLabelColor)
            )
        }

        switch monitor.accessState {
        case .notRequested:
            return SettingsStatus(
                title: "Setup needed",
                systemImage: "exclamationmark.circle.fill",
                color: .orange
            )
        case .needsPermission:
            return SettingsStatus(
                title: "Permission required",
                systemImage: "exclamationmark.circle.fill",
                color: .orange
            )
        case .needsAlwaysAllow:
            return SettingsStatus(
                title: "Always Allow required",
                systemImage: "exclamationmark.triangle.fill",
                color: .orange
            )
        case .allowed where monitor.isPaused:
            return SettingsStatus(
                title: "Paused",
                systemImage: "pause.circle.fill",
                color: .orange
            )
        case .allowed:
            return SettingsStatus(
                title: "Active",
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        case .denied:
            return SettingsStatus(
                title: "Denied",
                systemImage: "xmark.octagon.fill",
                color: .red
            )
        }
    }

    private var historyStorageStatus: SettingsStatus {
        if store.isResettingPersistence {
            return SettingsStatus(
                title: "Resetting",
                systemImage: "arrow.triangle.2.circlepath",
                color: .orange
            )
        }
        if store.isRetryingPersistence {
            return SettingsStatus(
                title: "Retrying",
                systemImage: "arrow.clockwise.circle.fill",
                color: .orange
            )
        }
        if store.isLoading {
            return SettingsStatus(
                title: "Loading",
                systemImage: "clock.fill",
                color: Color(nsColor: .secondaryLabelColor)
            )
        }
        if store.persistenceError != nil {
            return SettingsStatus(
                title: "Needs attention",
                systemImage: "exclamationmark.octagon.fill",
                color: .red
            )
        }
        return SettingsStatus(
            title: "Ready",
            systemImage: "lock.circle.fill",
            color: .green
        )
    }

    private var isHistoryStorageBusy: Bool {
        store.isLoading
            || store.isRetryingPersistence
            || store.isResettingPersistence
    }

    private func chooseExcludedApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an application whose copies Clops should ignore."
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else { return }
        preferences.addExcludedApplication(bundleIdentifier: bundleIdentifier)
    }

    private func openClipboardSettings() {
        let path = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard"
        if let url = URL(string: path), NSWorkspace.shared.open(url) { return }
        let fallback = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        guard let url = URL(string: fallback) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct SettingsStatus {
    let title: String
    let systemImage: String
    let color: Color
}

private struct SettingsMessage {
    let text: String
    let color: Color
}

private struct SettingsStatusLabel: View {
    let status: SettingsStatus

    var body: some View {
        Label {
            Text(status.title)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: status.systemImage)
                .foregroundStyle(status.color)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
