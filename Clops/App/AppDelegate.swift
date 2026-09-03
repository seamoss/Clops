import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let preferences: AppPreferences
    let store: ClipboardStore
    let monitor: ClipboardMonitor
    let coordinator: PasteCoordinator

    private let isUnitTestHost: Bool
    private let popover = NSPopover()
    private let toastPresenter = ToastPresenter()
    private var statusItem: NSStatusItem?
    lazy var hotKey = GlobalHotKey { [weak self] in self?.togglePopover() }
    private var cancellables: Set<AnyCancellable> = []
    private var copyFeedbackTask: Task<Void, Never>?
    private var popoverCloseTask: Task<Void, Never>?
    private var isShowingCopyFeedback = false
    private var terminationReplyPending = false

    private static let copyPulseAnimationKey = "Clops.copyPulse"

    override init() {
        let isUnitTestHost = Self.isUnitTestHost()
        let preferences: AppPreferences
        let store: ClipboardStore
        let monitor: ClipboardMonitor

        if isUnitTestHost {
            // ClopsTests is hosted inside the app executable. Keep creation of
            // the SwiftUI app delegate from loading the user's real defaults,
            // pasteboard, history file, or Keychain key before tests begin.
            let runID = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
            let defaults = UserDefaults(
                suiteName: "com.seamoss.Clops.UnitTestHost.\(runID)"
            )!
            preferences = AppPreferences(
                defaults: defaults,
                launchAtLoginService: UnitTestLaunchAtLoginService(),
                applicationURL: FileManager.default.temporaryDirectory
            )
            store = ClipboardStore(
                storageURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("Clops-UnitTestHost", isDirectory: true)
                    .appendingPathComponent(runID, isDirectory: true)
                    .appendingPathComponent("clipboard-history.clops"),
                maxHistoryItems: preferences.maxHistoryItems,
                retentionDays: preferences.retentionDays,
                fixedEncryptionKey: Data(repeating: 0x43, count: 32)
            )
            monitor = ClipboardMonitor(
                pasteboard: NSPasteboard(
                    name: NSPasteboard.Name("com.seamoss.Clops.UnitTestHost.\(runID)")
                ),
                store: store,
                preferences: preferences,
                accessBehaviorProvider: { .alwaysAllow }
            )
        } else {
            preferences = AppPreferences()
            store = ClipboardStore(
                maxHistoryItems: preferences.maxHistoryItems,
                retentionDays: preferences.retentionDays
            )
            monitor = ClipboardMonitor(store: store, preferences: preferences)
        }

        self.isUnitTestHost = isUnitTestHost
        self.preferences = preferences
        self.store = store
        self.monitor = monitor
        self.coordinator = PasteCoordinator(monitor: monitor, preferences: preferences)
        super.init()

        coordinator.closePicker = { [weak self] in self?.closePopover() }
        coordinator.showToast = { [weak self] message in self?.toastPresenter.show(message) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !isUnitTestHost else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()
        configureBindings()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        monitor.start()

        hotKey.register()

        let shouldSurfaceClipboardSetup = preferences.backgroundCaptureEnabled
            && monitor.accessState != .allowed
        if preferences.isFirstLaunch || shouldSurfaceClipboardSetup {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                self?.showPopover()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isUnitTestHost else { return }
        monitor.refreshAccessState()
        coordinator.refreshPasteAccessStatus()
        preferences.refreshLaunchAtLoginStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isUnitTestHost else { return }
        hotKey.unregister()
        monitor.stop()
        resetCopyFeedback()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isUnitTestHost else { return .terminateNow }
        guard !terminationReplyPending else { return .terminateLater }
        terminationReplyPending = true
        monitor.stop()
        store.prepareForTermination()
        closePopover()

        Task { @MainActor [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }

            switch await store.flushPersistence() {
            case .success:
                sender.reply(toApplicationShouldTerminate: true)
            case let .failure(error):
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Clipboard history couldn’t be saved"
                alert.informativeText = "\(error.localizedDescription)\n\nQuit anyway and discard the latest unsaved changes?"
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Quit Without Saving")
                let shouldQuit = alert.runModal() == .alertSecondButtonReturn
                if !shouldQuit {
                    terminationReplyPending = false
                    store.resumeAfterCancelledTermination()
                    monitor.start()
                    coordinator.restoreTargetApplication()
                }
                sender.reply(toApplicationShouldTerminate: shouldQuit)
            }
        }
        return .terminateLater
    }

    static func isUnitTestHost(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        hasXCTestRuntime: Bool = NSClassFromString("XCTestCase") != nil
    ) -> Bool {
        hasXCTestRuntime
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCInjectBundleInto"] != nil
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked)
        }
        statusItem = item
        updateStatusItemAppearance(
            paused: monitor.isPaused,
            shortcutLabel: hotKey.activeShortcutLabel
        )
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 390, height: 550)
        popover.contentViewController = NSHostingController(
            rootView: ClipboardHistoryView(
                store: store,
                monitor: monitor,
                coordinator: coordinator,
                hotKey: hotKey
            )
        )
    }

    private func configureBindings() {
        monitor.$isPaused
            .combineLatest(hotKey.$activeShortcutLabel)
            .sink { [weak self] paused, shortcutLabel in
                self?.updateStatusItemAppearance(paused: paused, shortcutLabel: shortcutLabel)
            }
            .store(in: &cancellables)

        monitor.copyActivityPublisher
            .sink { [weak self] activity in
                self?.showCopyFeedback(burstCount: activity.burstCount)
            }
            .store(in: &cancellables)

        preferences.$maxHistoryItems
            .combineLatest(preferences.$retentionDays)
            .dropFirst()
            .sink { [weak self] maxItems, retentionDays in
                self?.store.updateLimits(maxHistoryItems: maxItems, retentionDays: retentionDays)
            }
            .store(in: &cancellables)
    }

    @objc private func statusItemClicked() {
        togglePopover()
    }

    @objc private func workspaceApplicationActivated(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication else { return }
        monitor.applicationDidActivate(application)
    }

    private func togglePopover() {
        guard !terminationReplyPending else { return }
        if popover.isShown {
            coordinator.close()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        popoverCloseTask?.cancel()
        popoverCloseTask = nil
        // Capture any copy that happened just before the user summoned Clops,
        // while the source application is still known.
        monitor.poll()
        coordinator.clearNotice()
        coordinator.captureTargetApplication()
        popover.contentViewController = NSHostingController(
            rootView: ClipboardHistoryView(
                store: store,
                monitor: monitor,
                coordinator: coordinator,
                hotKey: hotKey
            )
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApplication.shared.activate()
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePopover() {
        popoverCloseTask?.cancel()
        popoverCloseTask = Task { @MainActor [weak self] in
            // A history action can originate inside an AppKit context-menu
            // tracking loop. Let that loop finish before dismissing the popover.
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.popoverCloseTask = nil
            self.popover.performClose(nil)
        }
    }

    private func statusImage(paused: Bool) -> NSImage? {
        let name = if paused {
            "pause.circle.fill"
        } else if isShowingCopyFeedback {
            "clipboard.fill"
        } else {
            "clipboard"
        }
        let description = paused ? "Clops, capture paused" : "Clops clipboard history"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    private func updateStatusItemAppearance(paused: Bool, shortcutLabel: String?) {
        guard let button = statusItem?.button else { return }
        if paused {
            resetCopyFeedback()
        }
        button.image = statusImage(paused: paused)

        if paused {
            button.toolTip = shortcutLabel.map { "Clops — Capture Paused (\($0))" }
                ?? "Clops — Capture Paused"
        } else {
            button.toolTip = shortcutLabel.map { "Clops Clipboard History (\($0))" }
                ?? "Clops Clipboard History — Shortcut unavailable"
        }
    }

    private func showCopyFeedback(burstCount: Int) {
        guard !monitor.isPaused, let button = statusItem?.button else { return }

        copyFeedbackTask?.cancel()
        isShowingCopyFeedback = true
        updateStatusItemAppearance(
            paused: false,
            shortcutLabel: hotKey.activeShortcutLabel
        )

        button.wantsLayer = true
        button.layer?.removeAnimation(forKey: Self.copyPulseAnimationKey)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let burstBoost = Double(min(max(burstCount - 1, 0), 3)) * 0.02
            let animation = CAKeyframeAnimation(keyPath: "transform.scale")
            animation.values = [1.0, 1.14 + burstBoost, 0.98, 1.0]
            animation.keyTimes = [0.0, 0.32, 0.7, 1.0]
            animation.duration = 0.34
            animation.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
                CAMediaTimingFunction(name: .easeOut),
            ]
            button.layer?.add(animation, forKey: Self.copyPulseAnimationKey)
        }

        copyFeedbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(420))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.copyFeedbackTask = nil
            self.isShowingCopyFeedback = false
            self.updateStatusItemAppearance(
                paused: self.monitor.isPaused,
                shortcutLabel: self.hotKey.activeShortcutLabel
            )
        }
    }

    private func resetCopyFeedback() {
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        isShowingCopyFeedback = false
        statusItem?.button?.layer?.removeAnimation(forKey: Self.copyPulseAnimationKey)
    }
}

@MainActor
private final class UnitTestLaunchAtLoginService: LaunchAtLoginServicing {
    let status: LaunchAtLoginServiceStatus = .notRegistered

    func register() throws {}
    func unregister() throws {}
    func openSystemSettings() {}
}
