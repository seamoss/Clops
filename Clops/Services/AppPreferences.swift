import Combine
import Foundation
import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case disabled
    case enabled
    case needsApproval
    case unavailable
}

enum LaunchAtLoginServiceStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unavailable
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginServiceStatus { get }

    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: LaunchAtLoginServiceStatus {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unavailable
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    private enum Key {
        static let maxHistoryItems = "maxHistoryItems"
        static let retentionDays = "retentionDays"
        static let captureImages = "captureImages"
        static let captureFiles = "captureFiles"
        static let pasteOnSelection = "pasteOnSelection"
        static let backgroundCaptureEnabled = "backgroundCaptureEnabled"
        static let excludedBundleIdentifiers = "excludedBundleIdentifiers"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }

    private let defaults: UserDefaults
    private let launchAtLoginService: any LaunchAtLoginServicing

    @Published var maxHistoryItems: Int {
        didSet { defaults.set(maxHistoryItems, forKey: Key.maxHistoryItems) }
    }

    @Published var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
    }

    @Published var captureImages: Bool {
        didSet { defaults.set(captureImages, forKey: Key.captureImages) }
    }

    @Published var captureFiles: Bool {
        didSet { defaults.set(captureFiles, forKey: Key.captureFiles) }
    }

    @Published var pasteOnSelection: Bool {
        didSet { defaults.set(pasteOnSelection, forKey: Key.pasteOnSelection) }
    }

    @Published var backgroundCaptureEnabled: Bool {
        didSet { defaults.set(backgroundCaptureEnabled, forKey: Key.backgroundCaptureEnabled) }
    }

    @Published private(set) var excludedBundleIdentifiers: Set<String> {
        didSet { defaults.set(Array(excludedBundleIdentifiers).sorted(), forKey: Key.excludedBundleIdentifiers) }
    }

    @Published private(set) var launchAtLoginState: LaunchAtLoginState
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var launchAtLoginNeedsRepair: Bool

    let isFirstLaunch: Bool
    let isRunningFromApplicationsDirectory: Bool

    init(
        defaults: UserDefaults = .standard,
        launchAtLoginService: any LaunchAtLoginServicing = SystemLaunchAtLoginService(),
        applicationURL: URL = Bundle.main.bundleURL
    ) {
        self.defaults = defaults
        self.launchAtLoginService = launchAtLoginService

        if defaults.object(forKey: Key.maxHistoryItems) == nil {
            defaults.set(500, forKey: Key.maxHistoryItems)
            defaults.set(30, forKey: Key.retentionDays)
            defaults.set(true, forKey: Key.captureImages)
            defaults.set(true, forKey: Key.captureFiles)
            defaults.set(true, forKey: Key.pasteOnSelection)
            defaults.set(false, forKey: Key.backgroundCaptureEnabled)
        }

        maxHistoryItems = max(defaults.integer(forKey: Key.maxHistoryItems), 25)
        retentionDays = max(defaults.integer(forKey: Key.retentionDays), 1)
        captureImages = defaults.bool(forKey: Key.captureImages)
        captureFiles = defaults.bool(forKey: Key.captureFiles)
        pasteOnSelection = defaults.bool(forKey: Key.pasteOnSelection)
        backgroundCaptureEnabled = defaults.bool(forKey: Key.backgroundCaptureEnabled)
        excludedBundleIdentifiers = Set(defaults.stringArray(forKey: Key.excludedBundleIdentifiers) ?? [])
        launchAtLoginState = Self.mapLaunchAtLoginStatus(launchAtLoginService.status)
        launchAtLoginError = nil
        launchAtLoginNeedsRepair = false
        isFirstLaunch = !defaults.bool(forKey: Key.hasLaunchedBefore)
        isRunningFromApplicationsDirectory = Self.isApplicationsDirectoryURL(applicationURL)
        defaults.set(true, forKey: Key.hasLaunchedBefore)
    }

    var launchAtLoginEnabled: Bool { launchAtLoginState == .enabled }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        launchAtLoginError = nil

        if launchAtLoginNeedsRepair {
            if enabled {
                repairLaunchAtLoginRegistration()
            } else {
                launchAtLoginNeedsRepair = false
                performLaunchAtLoginOperation(.disable) {
                    try launchAtLoginService.unregister()
                }
            }
            return
        }

        switch (enabled, launchAtLoginService.status) {
        case (true, .enabled):
            updateLaunchAtLoginState()
        case (true, .requiresApproval):
            updateLaunchAtLoginState()
            openLaunchAtLoginSettings()
        case (true, .notRegistered), (true, .notFound):
            performLaunchAtLoginOperation(.enable) {
                try launchAtLoginService.register()
            }
        case (false, .enabled), (false, .requiresApproval):
            performLaunchAtLoginOperation(.disable) {
                try launchAtLoginService.unregister()
            }
        case (false, .notRegistered), (false, .notFound):
            updateLaunchAtLoginState()
        case (_, .unavailable):
            reportUnavailableLaunchAtLoginStatus()
        }
    }

    func repairLaunchAtLoginRegistration() {
        guard launchAtLoginNeedsRepair else {
            refreshLaunchAtLoginStatus()
            return
        }
        launchAtLoginError = nil
        performLaunchAtLoginRepair()
    }

    func openLaunchAtLoginSettings() {
        launchAtLoginService.openSystemSettings()
    }

    func retryLaunchAtLoginStatus() {
        launchAtLoginError = nil
        reportUnavailableLaunchAtLoginStatus()
    }

    func toggleLaunchAtLogin() {
        launchAtLoginError = nil

        if launchAtLoginNeedsRepair {
            repairLaunchAtLoginRegistration()
            return
        }

        switch launchAtLoginState {
        case .disabled:
            setLaunchAtLoginEnabled(true)
        case .enabled:
            setLaunchAtLoginEnabled(false)
        case .needsApproval:
            openLaunchAtLoginSettings()
        case .unavailable:
            retryLaunchAtLoginStatus()
        }
    }

    func refreshLaunchAtLoginStatus() {
        let status = launchAtLoginService.status
        if launchAtLoginNeedsRepair, status == .notFound {
            launchAtLoginState = Self.mapLaunchAtLoginStatus(status)
            return
        }

        launchAtLoginError = nil
        launchAtLoginNeedsRepair = false
        launchAtLoginState = Self.mapLaunchAtLoginStatus(status)
    }

    func addExcludedApplication(bundleIdentifier: String) {
        excludedBundleIdentifiers.insert(bundleIdentifier)
    }

    func removeExcludedApplication(bundleIdentifier: String) {
        excludedBundleIdentifiers.remove(bundleIdentifier)
    }

    static func isApplicationsDirectoryURL(_ url: URL) -> Bool {
        let components = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard components.count >= 3 else { return false }

        if components[1] == "Applications" {
            return true
        }

        return components.count >= 5
            && components[1] == "Users"
            && components[3] == "Applications"
    }

    private enum LaunchAtLoginOperation {
        case enable
        case disable

        var verb: String {
            switch self {
            case .enable: "enable"
            case .disable: "disable"
            }
        }
    }

    private func performLaunchAtLoginOperation(
        _ operation: LaunchAtLoginOperation,
        action: () throws -> Void
    ) {
        launchAtLoginNeedsRepair = false
        do {
            try action()
            updateLaunchAtLoginState()
        } catch {
            updateLaunchAtLoginState()
            handleLaunchAtLoginError(error, operation: operation)
        }
    }

    private func performLaunchAtLoginRepair() {
        launchAtLoginNeedsRepair = false

        switch launchAtLoginService.status {
        case .enabled:
            updateLaunchAtLoginState()
            return
        case .requiresApproval:
            updateLaunchAtLoginState()
            openLaunchAtLoginSettings()
            return
        case .notRegistered:
            performLaunchAtLoginOperation(.enable) {
                try launchAtLoginService.register()
            }
            return
        case .unavailable:
            reportUnavailableLaunchAtLoginStatus()
            return
        case .notFound:
            break
        }

        do {
            do {
                try launchAtLoginService.unregister()
            } catch where serviceManagementCode(for: error) == kSMErrorJobNotFound {
                // The stale record disappeared between status checks. Register below.
            }
            try launchAtLoginService.register()
            updateLaunchAtLoginState()
        } catch {
            updateLaunchAtLoginState()
            handleLaunchAtLoginError(error, operation: .enable)
        }
    }

    private func updateLaunchAtLoginState() {
        launchAtLoginState = Self.mapLaunchAtLoginStatus(launchAtLoginService.status)
    }

    private func reportUnavailableLaunchAtLoginStatus() {
        updateLaunchAtLoginState()
        if launchAtLoginState == .unavailable {
            launchAtLoginError = "macOS couldn’t read Clops’s Launch at Login status. Try again after relaunching Clops."
        } else {
            launchAtLoginError = nil
        }
    }

    private func handleLaunchAtLoginError(
        _ error: Error,
        operation: LaunchAtLoginOperation
    ) {
        let nsError = error as NSError
        let code = serviceManagementCode(for: error)

        switch (operation, code) {
        case (.enable, kSMErrorLaunchDeniedByUser):
            launchAtLoginState = .needsApproval
            launchAtLoginError = "macOS needs your approval before Clops can start at login. Open Login Items and allow Clops."
        case (.enable, kSMErrorInvalidSignature):
            launchAtLoginError = "This copy of Clops does not have a valid code signature. Install or rebuild a validly signed copy, then try again. For Xcode builds, choose a Development Team and refresh its Apple Development certificate."
        case (.enable, kSMErrorAlreadyRegistered)
            where launchAtLoginState == .enabled || launchAtLoginState == .needsApproval:
            launchAtLoginError = nil
        case (.enable, kSMErrorAlreadyRegistered):
            launchAtLoginNeedsRepair = true
            launchAtLoginError = "macOS has a stale registration for another Clops copy. Quit other copies, then click Repair to replace it with this one."
        case (.disable, kSMErrorJobNotFound):
            launchAtLoginState = .disabled
            launchAtLoginError = nil
        default:
            launchAtLoginError = "Clops couldn’t \(operation.verb) Launch at Login. \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
        }
    }

    private func serviceManagementCode(for error: Error) -> Int? {
        let nsError = error as NSError
        return nsError.domain == SMAppServiceErrorDomain ? nsError.code : nil
    }

    private static func mapLaunchAtLoginStatus(
        _ status: LaunchAtLoginServiceStatus
    ) -> LaunchAtLoginState {
        switch status {
        case .notRegistered, .notFound: .disabled
        case .enabled: .enabled
        case .requiresApproval: .needsApproval
        case .unavailable: .unavailable
        }
    }
}
