import AppKit
import Combine
import CoreGraphics
import Foundation

enum PasteOutcome: Equatable {
    case pasteScheduled(appName: String?)
    case copied
    case failed
}

enum ClipboardUseIntent: Equatable {
    case preferred
    case paste
    case copy
    case pastePlainText
    case copyPlainText
}

@MainActor
final class PasteCoordinator: ObservableObject {
    @Published private(set) var notice: String?
#if MAC_APP_STORE
    @Published private(set) var pasteAccessGranted = false
#else
    @Published private(set) var pasteAccessGranted = CGPreflightPostEventAccess()
#endif

    private let monitor: ClipboardMonitor
    private let preferences: AppPreferences
    private var targetApplication: NSRunningApplication?
    var closePicker: (() -> Void)?
    var showToast: ((String) -> Void)?

    init(monitor: ClipboardMonitor, preferences: AppPreferences) {
        self.monitor = monitor
        self.preferences = preferences
    }

    var targetAppName: String? { targetApplication?.localizedName }
    var willPastePreferredAction: Bool {
#if MAC_APP_STORE
        false
#else
        preferences.pasteOnSelection && pasteAccessGranted && targetApplication != nil
#endif
    }

    func captureTargetApplication() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            targetApplication = frontmost
        } else {
            targetApplication = nil
        }
        refreshPasteAccessStatus()
    }

    @discardableResult
    func use(_ entry: ClipboardEntry, intent: ClipboardUseIntent = .preferred) -> PasteOutcome {
        let plainTextOnly = intent == .pastePlainText || intent == .copyPlainText
#if MAC_APP_STORE
        let pasteRequested = switch intent {
        case .preferred, .paste, .pastePlainText: true
        case .copy, .copyPlainText: false
        }
#else
        let pasteRequested = switch intent {
        case .preferred: preferences.pasteOnSelection
        case .paste, .pastePlainText: true
        case .copy, .copyPlainText: false
        }
#endif

#if !MAC_APP_STORE
        let shouldPaste = pasteRequested
        pasteAccessGranted = CGPreflightPostEventAccess()
        let explicitlyRequestedPaste = intent == .paste || intent == .pastePlainText
        if shouldPaste, explicitlyRequestedPaste, !pasteAccessGranted, targetApplication != nil {
            pasteAccessGranted = CGRequestPostEventAccess()
        }
#endif

        guard let expectedChangeCount = monitor.copy(entry, plainTextOnly: plainTextOnly) else {
            showNotice("Couldn’t copy that item")
            return .failed
        }

#if MAC_APP_STORE
        _ = expectedChangeCount
        closePicker?()
        reactivateTargetIfPossible()
        showToast?(pasteRequested ? "Copied — press ⌘V" : "Copied")
        return .copied
#else
        guard
            shouldPaste,
            pasteAccessGranted,
            let targetApplication,
            !targetApplication.isTerminated
        else {
            closePicker?()
            if shouldPaste {
                reactivateTargetIfPossible()
                showToast?("Copied — press ⌘V")
            } else {
                reactivateTargetIfPossible()
                showToast?("Copied")
            }
            return .copied
        }

        let appName = targetApplication.localizedName
        closePicker?()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(110))
            guard await Self.activate(targetApplication) else {
                self.showToast?("Copied — press ⌘V")
                return
            }
            guard
                CGPreflightPostEventAccess(),
                self.monitor.currentChangeCount == expectedChangeCount,
                NSWorkspace.shared.frontmostApplication == targetApplication,
                Self.postCommandV(to: targetApplication.processIdentifier)
            else {
                self.showToast?("Copied — press ⌘V")
                return
            }
        }
        return .pasteScheduled(appName: appName)
#endif
    }

    func requestPasteAccess() {
#if !MAC_APP_STORE
        pasteAccessGranted = CGRequestPostEventAccess()
#endif
    }

    func refreshPasteAccessStatus() {
#if !MAC_APP_STORE
        pasteAccessGranted = CGPreflightPostEventAccess()
#endif
    }

    func clearNotice() {
        notice = nil
    }

    func close() {
        closePicker?()
        restoreTargetApplication()
    }

    func restoreTargetApplication() {
        guard targetApplication != nil else {
            NSApplication.shared.deactivate()
            return
        }
        reactivateTargetIfPossible()
    }

    private func showNotice(_ value: String) {
        notice = value
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard self?.notice == value else { return }
            self?.notice = nil
        }
    }

    private func reactivateTargetIfPossible() {
        guard let targetApplication, !targetApplication.isTerminated else { return }
        Task { @MainActor in
            _ = await Self.activate(targetApplication)
        }
    }

    private static func activate(_ application: NSRunningApplication) async -> Bool {
        let currentApplication = NSRunningApplication.current
        NSApplication.shared.yieldActivation(to: application)
        guard application.activate(from: currentApplication, options: []) else { return false }

        for _ in 0..<8 {
            if NSWorkspace.shared.frontmostApplication == application { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return NSWorkspace.shared.frontmostApplication == application
    }

#if !MAC_APP_STORE
    private static func postCommandV(to processIdentifier: pid_t) -> Bool {
        guard let virtualKey = KeyboardLayoutKeyResolver.virtualKeyCode(for: "v") else {
            return false
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
        return true
    }
#endif
}
