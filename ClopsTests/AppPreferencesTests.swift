import Foundation
import ServiceManagement
import XCTest
@testable import Clops

@MainActor
final class TestLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus
    var statusAfterRegister: LaunchAtLoginServiceStatus?
    var statusAfterUnregister: LaunchAtLoginServiceStatus?
    var registerError: Error?
    var unregisterError: Error?

    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSystemSettingsCallCount = 0

    init(status: LaunchAtLoginServiceStatus = .notRegistered) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let statusAfterRegister {
            status = statusAfterRegister
        }
        if let registerError {
            throw registerError
        }
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let statusAfterUnregister {
            status = statusAfterUnregister
        }
        if let unregisterError {
            throw unregisterError
        }
    }

    func openSystemSettings() {
        openSystemSettingsCallCount += 1
    }
}

@MainActor
final class AppPreferencesTests: XCTestCase {
    func testLaunchAtLoginEnabledReflectsEffectiveServiceState() {
        let service = TestLaunchAtLoginService(status: .enabled)
        let preferences = makePreferences(service: service)

        XCTAssertTrue(preferences.launchAtLoginEnabled)

        service.status = .requiresApproval
        preferences.refreshLaunchAtLoginStatus()
        XCTAssertFalse(preferences.launchAtLoginEnabled)

        service.status = .notRegistered
        preferences.refreshLaunchAtLoginStatus()
        XCTAssertFalse(preferences.launchAtLoginEnabled)

        service.status = .unavailable
        preferences.refreshLaunchAtLoginStatus()
        XCTAssertFalse(preferences.launchAtLoginEnabled)
    }

    func testExplicitEnableRegistersDisabledService() {
        let service = TestLaunchAtLoginService(status: .notRegistered)
        service.statusAfterRegister = .enabled
        let preferences = makePreferences(service: service)

        preferences.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(preferences.launchAtLoginState, .enabled)
        XCTAssertTrue(preferences.launchAtLoginEnabled)
    }

    func testExplicitDisableUnregistersApprovalPendingService() {
        let service = TestLaunchAtLoginService(status: .requiresApproval)
        service.statusAfterUnregister = .notRegistered
        let preferences = makePreferences(service: service)

        preferences.setLaunchAtLoginEnabled(false)

        XCTAssertEqual(service.openSystemSettingsCallCount, 0)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(preferences.launchAtLoginState, .disabled)
        XCTAssertFalse(preferences.launchAtLoginEnabled)
    }

    func testExplicitEnablePendingApprovalOpensSettingsWithoutMutation() {
        let service = TestLaunchAtLoginService(status: .requiresApproval)
        let preferences = makePreferences(service: service)

        preferences.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(service.openSystemSettingsCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(preferences.launchAtLoginState, .needsApproval)
        XCTAssertFalse(preferences.launchAtLoginEnabled)
    }

    func testExplicitEnableDoesNotInvertStaleDisabledState() {
        let service = TestLaunchAtLoginService(status: .notRegistered)
        let preferences = makePreferences(service: service)
        service.status = .enabled

        preferences.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(preferences.launchAtLoginState, .enabled)
    }

    func testExplicitDisableDoesNotInvertStaleEnabledState() {
        let service = TestLaunchAtLoginService(status: .enabled)
        let preferences = makePreferences(service: service)
        service.status = .notRegistered

        preferences.setLaunchAtLoginEnabled(false)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(preferences.launchAtLoginState, .disabled)
    }

    func testNotFoundRegistrationCanRecoverToEnabled() {
        let service = TestLaunchAtLoginService(status: .notFound)
        service.statusAfterRegister = .enabled
        let preferences = makePreferences(service: service)

        XCTAssertEqual(preferences.launchAtLoginState, .disabled)

        preferences.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(preferences.launchAtLoginState, .enabled)
        XCTAssertNil(preferences.launchAtLoginError)
    }

    func testEnabledRegistrationCanBeDisabled() {
        let service = TestLaunchAtLoginService(status: .enabled)
        service.statusAfterUnregister = .notRegistered
        let preferences = makePreferences(service: service)

        preferences.setLaunchAtLoginEnabled(false)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(preferences.launchAtLoginState, .disabled)
        XCTAssertNil(preferences.launchAtLoginError)
    }

    func testApprovalStateOpensLoginItemSettingsWithoutRegisteringAgain() {
        let service = TestLaunchAtLoginService(status: .requiresApproval)
        let preferences = makePreferences(service: service)

        preferences.openLaunchAtLoginSettings()

        XCTAssertEqual(service.openSystemSettingsCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(preferences.launchAtLoginState, .needsApproval)
        XCTAssertNil(preferences.launchAtLoginError)
    }

    func testRefreshTracksExternalStatusChangeAndClearsOldError() {
        let service = TestLaunchAtLoginService(status: .notRegistered)
        service.registerError = NSError(domain: "TestLoginItem", code: 47)
        let preferences = makePreferences(service: service)
        preferences.setLaunchAtLoginEnabled(true)
        XCTAssertNotNil(preferences.launchAtLoginError)

        service.status = .requiresApproval
        preferences.refreshLaunchAtLoginStatus()

        XCTAssertEqual(preferences.launchAtLoginState, .needsApproval)
        XCTAssertNil(preferences.launchAtLoginError)
    }

    func testLaunchDeniedErrorBecomesApprovalGuidance() {
        let service = TestLaunchAtLoginService(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        service.registerError = serviceManagementError(kSMErrorLaunchDeniedByUser)
        let preferences = makePreferences(service: service)

        preferences.setLaunchAtLoginEnabled(true)

        XCTAssertEqual(preferences.launchAtLoginState, .needsApproval)
        XCTAssertEqual(
            preferences.launchAtLoginError,
            "macOS needs your approval before Clops can start at login. Open Login Items and allow Clops."
        )
    }

    func testUndocumentedOperationNotPermittedErrorIsNotMisreportedAsApproval() {
        let service = TestLaunchAtLoginService(status: .notRegistered)
        service.registerError = serviceManagementError(1)
        let preferences = makePreferences(service: service)

        preferences.toggleLaunchAtLogin()

        XCTAssertEqual(preferences.launchAtLoginState, .disabled)
        XCTAssertNotEqual(preferences.launchAtLoginState, .needsApproval)
        XCTAssertTrue(preferences.launchAtLoginError?.contains("SMAppServiceErrorDomain 1") == true)
    }

    func testInvalidSignatureErrorBecomesSigningGuidance() {
        let service = TestLaunchAtLoginService(status: .notRegistered)
        service.registerError = serviceManagementError(kSMErrorInvalidSignature)
        let preferences = makePreferences(service: service)

        preferences.toggleLaunchAtLogin()

        XCTAssertEqual(preferences.launchAtLoginState, .disabled)
        XCTAssertEqual(
            preferences.launchAtLoginError,
            "This copy of Clops does not have a valid code signature. Install or rebuild a validly signed copy, then try again. For Xcode builds, choose a Development Team and refresh its Apple Development certificate."
        )
    }

    func testAlreadyRegisteredRaceIsAcceptedWhenServiceReportsEnabled() {
        let service = TestLaunchAtLoginService(status: .notRegistered)
        service.statusAfterRegister = .enabled
        service.registerError = serviceManagementError(kSMErrorAlreadyRegistered)
        let preferences = makePreferences(service: service)

        preferences.toggleLaunchAtLogin()

        XCTAssertEqual(preferences.launchAtLoginState, .enabled)
        XCTAssertNil(preferences.launchAtLoginError)
    }

    func testMissingJobRaceIsAcceptedWhenDisabling() {
        let service = TestLaunchAtLoginService(status: .enabled)
        service.statusAfterUnregister = .notRegistered
        service.unregisterError = serviceManagementError(kSMErrorJobNotFound)
        let preferences = makePreferences(service: service)

        preferences.toggleLaunchAtLogin()

        XCTAssertEqual(preferences.launchAtLoginState, .disabled)
        XCTAssertNil(preferences.launchAtLoginError)
    }

    func testUnavailableStatusReportsActionableErrorWithoutMutation() {
        let service = TestLaunchAtLoginService(status: .unavailable)
        let preferences = makePreferences(service: service)

        preferences.retryLaunchAtLoginStatus()

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(service.openSystemSettingsCallCount, 0)
        XCTAssertEqual(preferences.launchAtLoginState, .unavailable)
        XCTAssertEqual(
            preferences.launchAtLoginError,
            "macOS couldn’t read Clops’s Launch at Login status. Try again after relaunching Clops."
        )
    }

    func testUnavailableRetryOnlyRefreshesWhenServiceHasBecomeEnabled() {
        let service = TestLaunchAtLoginService(status: .unavailable)
        let preferences = makePreferences(service: service)
        service.status = .enabled

        preferences.retryLaunchAtLoginStatus()

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(preferences.launchAtLoginState, .enabled)
        XCTAssertNil(preferences.launchAtLoginError)
    }

    func testDisplayedApprovalActionDoesNotDisableAfterExternalApproval() {
        let service = TestLaunchAtLoginService(status: .requiresApproval)
        let preferences = makePreferences(service: service)
        service.status = .enabled
        preferences.refreshLaunchAtLoginStatus()

        preferences.openLaunchAtLoginSettings()

        XCTAssertEqual(service.openSystemSettingsCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
    }

    func testUnresolvedExistingRegistrationOffersAndPerformsExplicitRepair() {
        let service = TestLaunchAtLoginService(status: .notFound)
        service.registerError = serviceManagementError(kSMErrorAlreadyRegistered)
        let preferences = makePreferences(service: service)

        preferences.setLaunchAtLoginEnabled(true)

        XCTAssertTrue(preferences.launchAtLoginNeedsRepair)
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertFalse(preferences.launchAtLoginEnabled)

        service.registerError = nil
        service.statusAfterUnregister = .notRegistered
        service.statusAfterRegister = .enabled
        preferences.repairLaunchAtLoginRegistration()

        XCTAssertFalse(preferences.launchAtLoginNeedsRepair)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.registerCallCount, 2)
        XCTAssertEqual(preferences.launchAtLoginState, .enabled)
        XCTAssertNil(preferences.launchAtLoginError)
    }

    func testStaleRepairActionDoesNotEnableOrDisableAfterExternalRecovery() {
        let service = TestLaunchAtLoginService(status: .notFound)
        service.registerError = serviceManagementError(kSMErrorAlreadyRegistered)
        let preferences = makePreferences(service: service)
        preferences.toggleLaunchAtLogin()
        XCTAssertTrue(preferences.launchAtLoginNeedsRepair)

        service.registerError = nil
        service.status = .enabled
        preferences.refreshLaunchAtLoginStatus()
        preferences.repairLaunchAtLoginRegistration()

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(preferences.launchAtLoginState, .enabled)
        XCTAssertFalse(preferences.launchAtLoginNeedsRepair)
    }

    func testRefreshPreservesPendingRepairWhileRegistrationIsStillNotFound() {
        let service = TestLaunchAtLoginService(status: .notFound)
        service.registerError = serviceManagementError(kSMErrorAlreadyRegistered)
        let preferences = makePreferences(service: service)
        preferences.toggleLaunchAtLogin()
        let repairError = preferences.launchAtLoginError

        preferences.refreshLaunchAtLoginStatus()

        XCTAssertTrue(preferences.launchAtLoginNeedsRepair)
        XCTAssertEqual(preferences.launchAtLoginError, repairError)
        XCTAssertEqual(preferences.launchAtLoginState, .disabled)
    }

    func testApplicationsDirectoryClassification() {
        XCTAssertTrue(
            AppPreferences.isApplicationsDirectoryURL(
                URL(fileURLWithPath: "/Applications/Clops.app")
            )
        )
        XCTAssertTrue(
            AppPreferences.isApplicationsDirectoryURL(
                URL(fileURLWithPath: "/Users/example/Applications/Clops.app")
            )
        )
        XCTAssertFalse(
            AppPreferences.isApplicationsDirectoryURL(
                URL(fileURLWithPath: "/Users/example/Developer/Clops.app")
            )
        )
        XCTAssertFalse(
            AppPreferences.isApplicationsDirectoryURL(
                URL(fileURLWithPath: "/Users/example/Developer/Applications/Clops.app")
            )
        )
        XCTAssertFalse(
            AppPreferences.isApplicationsDirectoryURL(
                URL(fileURLWithPath: "/Applications-Old/Clops.app")
            )
        )
    }

    private func makePreferences(
        service: TestLaunchAtLoginService,
        applicationURL: URL = URL(fileURLWithPath: "/Applications/Clops.app")
    ) -> AppPreferences {
        let defaults = UserDefaults(
            suiteName: "AppPreferencesTests.\(UUID().uuidString)"
        )!
        return AppPreferences(
            defaults: defaults,
            launchAtLoginService: service,
            applicationURL: applicationURL
        )
    }

    private func serviceManagementError(_ code: Int) -> NSError {
        NSError(domain: SMAppServiceErrorDomain, code: code)
    }
}
