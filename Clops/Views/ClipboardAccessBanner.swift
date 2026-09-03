import AppKit
import SwiftUI

struct ClipboardAccessBanner: View {
    let state: ClipboardAccessState
    let requestAccess: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Button(buttonTitle) {
                if state == .needsAlwaysAllow || state == .denied {
                    openClipboardSettings()
                } else {
                    requestAccess()
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    private var title: String {
        switch state {
        case .notRequested: "Start clipboard watching"
        case .needsPermission: "Finish clipboard access"
        case .needsAlwaysAllow: "Allow background access"
        case .denied: "Clipboard access is off"
        case .allowed: "Clipboard access enabled"
        }
    }

    private var message: String {
        switch state {
        case .notRequested:
            "Continue to let macOS ask before Clops reads other apps' copies. Then enable Always Allow in System Settings for background history."
        case .needsPermission:
            "If no prompt appeared, copy something and click Continue. Allow the requested read, then enable Always Allow in System Settings."
        case .needsAlwaysAllow:
            "Clops is set to Ask. Choose Always Allow under Privacy & Security → Paste from Other Apps for background history."
        case .denied:
            "Choose Always Allow for Clops under Privacy & Security → Paste from Other Apps."
        case .allowed:
            "New copies are being added to your local history."
        }
    }

    private var buttonTitle: String {
        switch state {
        case .notRequested: "Enable"
        case .needsPermission: "Continue"
        case .needsAlwaysAllow: "Open Settings"
        case .denied: "Open Settings"
        case .allowed: "Enabled"
        }
    }

    private var iconName: String {
        state == .denied ? "exclamationmark.shield" : "hand.raised.fill"
    }

    private var iconColor: Color {
        state == .denied ? .orange : .accentColor
    }

    private func openClipboardSettings() {
        let path = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard"
        if let url = URL(string: path), NSWorkspace.shared.open(url) {
            return
        }
        let fallback = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        if let url = URL(string: fallback) {
            NSWorkspace.shared.open(url)
        }
    }
}
