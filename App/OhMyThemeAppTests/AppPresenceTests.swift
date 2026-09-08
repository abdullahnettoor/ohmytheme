import Foundation
import PlatformClients
import ThemeEngine
import ThemeModel
import XCTest

@testable import OhMyTheme

@MainActor
final class AppPresenceTests: XCTestCase {
    private var platform: FakeAppPresencePlatform!
    private var launchAtLogin: FakeLaunchAtLoginPlatform!
    private var defaults: FakeAppPresenceDefaults!
    private var runtime: FakeWorkspaceRuntime!

    override func setUp() async throws {
        try await super.setUp()
        platform = FakeAppPresencePlatform()
        launchAtLogin = FakeLaunchAtLoginPlatform(status: .disabled)
        defaults = FakeAppPresenceDefaults()
        runtime = FakeWorkspaceRuntime(workspace: .myMac)
    }

    private func makeController(
        launchStatus: LaunchAtLoginStatus = .disabled,
        storedMenuBarVisible: Bool? = nil,
        persistenceError: String? = nil
    ) -> AppPresenceController {
        if let storedMenuBarVisible {
            defaults.set(storedMenuBarVisible, forKey: AppPresenceDefaultsKeys.isMenuBarVisible)
        }
        let rt = FakeWorkspaceRuntime(
            workspace: .myMac,
            persistenceError: persistenceError
        )
        launchAtLogin.status = launchStatus
        return AppPresenceController(
            platform: platform,
            launchAtLoginPlatform: launchAtLogin,
            defaults: defaults,
            runtime: rt
        )
    }

    // MARK: - 1. Single Main Window Reusability & Reopen
    func testReopeningPresentsExistingMainWindowInsteadOfDuplicate() {
        let controller = makeController()

        XCTAssertFalse(controller.isMainWindowOpen)
        XCTAssertEqual(platform.openMainWindowCallCount, 0)
        XCTAssertEqual(platform.focusMainWindowCallCount, 0)

        // Initial launch / presentation
        let handled1 = controller.handleReopen(hasVisibleWindows: false)
        XCTAssertTrue(handled1)
        XCTAssertTrue(controller.isMainWindowOpen)
        XCTAssertEqual(platform.openMainWindowCallCount, 1)
        XCTAssertEqual(platform.focusMainWindowCallCount, 0)

        // Repeated reopen focuses the reusable window instead of asking SwiftUI to open another one.
        let handled2 = controller.handleReopen(hasVisibleWindows: true)
        XCTAssertTrue(handled2)
        XCTAssertTrue(controller.isMainWindowOpen)
        XCTAssertEqual(platform.openMainWindowCallCount, 1)
        XCTAssertEqual(platform.focusMainWindowCallCount, 1)
    }

    func testOpeningMainWindowExplicitlyActivatesAppAndPresentsWindow() {
        let controller = makeController()

        controller.openMainWindow()

        XCTAssertTrue(controller.isMainWindowOpen)
        XCTAssertEqual(platform.openMainWindowCallCount, 1)
        XCTAssertEqual(platform.focusMainWindowCallCount, 0)
        XCTAssertEqual(platform.activateAppCallCount, 1)
        XCTAssertEqual(platform.activationPolicy, .regular)
    }

    // MARK: - 2. Regular vs Accessory Transitions & Dock Icon
    func testInitialStateIsAccessoryWhenNoWindowIsOpen() {
        let controller = makeController()

        XCTAssertFalse(controller.isMainWindowOpen)
        XCTAssertEqual(platform.activationPolicy, .accessory)
    }

    func testOpeningMainWindowTransitionsToRegularActivationPolicy() {
        let controller = makeController()

        controller.mainWindowDidOpen()

        XCTAssertTrue(controller.isMainWindowOpen)
        XCTAssertEqual(platform.activationPolicy, .regular)
        XCTAssertEqual(platform.activationPolicyChanges, [.regular])
    }

    func testClosingLastMainWindowTransitionsBackToAccessoryMode() {
        let controller = makeController()

        controller.mainWindowDidOpen()
        XCTAssertEqual(platform.activationPolicy, .regular)

        controller.mainWindowDidClose()

        XCTAssertFalse(controller.isMainWindowOpen)
        XCTAssertEqual(platform.activationPolicy, .accessory)
        XCTAssertEqual(platform.activationPolicyChanges, [.regular, .accessory])
    }

    // MARK: - 3. Menu Bar Item Visibility Default & Customization
    func testMenuBarItemIsVisibleByDefault() {
        let controller = makeController()

        XCTAssertTrue(controller.isMenuBarVisible)
    }

    func testMenuBarItemHonorsStoredVisibilityPreference() {
        let hiddenController = makeController(storedMenuBarVisible: false)
        XCTAssertFalse(hiddenController.isMenuBarVisible)

        let visibleController = makeController(storedMenuBarVisible: true)
        XCTAssertTrue(visibleController.isMenuBarVisible)
    }

    func testStartupRestoresMenuBarWhenLaunchAtLoginIsStillActive() {
        let controller = makeController(launchStatus: .enabled, storedMenuBarVisible: false)

        XCTAssertTrue(controller.isMenuBarVisible)
        XCTAssertTrue(defaults.bool(forKey: AppPresenceDefaultsKeys.isMenuBarVisible))
        XCTAssertNotNil(controller.menuBarVisibilityError)
    }

    func testTogglingMenuBarVisibilityPersistsToDefaults() async {
        let controller = makeController()

        await controller.setMenuBarVisible(false)
        XCTAssertFalse(controller.isMenuBarVisible)
        XCTAssertEqual(defaults.bool(forKey: AppPresenceDefaultsKeys.isMenuBarVisible), false)

        await controller.setMenuBarVisible(true)
        XCTAssertTrue(controller.isMenuBarVisible)
        XCTAssertEqual(defaults.bool(forKey: AppPresenceDefaultsKeys.isMenuBarVisible), true)
    }

    func testBecomingVisibleClearsRememberedHiddenPreferences() async {
        defaults.set(true, forKey: "NSStatusItem Visible OhMyThemeItem-0")
        defaults.set("keep", forKey: "UnrelatedKey")

        let controller = makeController()
        await controller.setMenuBarVisible(true)

        XCTAssertTrue(defaults.removedKeys.contains("NSStatusItem Visible OhMyThemeItem-0"))
        XCTAssertFalse(defaults.removedKeys.contains("UnrelatedKey"))
    }

    // MARK: - 4. Launch at Login Eligibility & Explanation
    func testHidingMenuBarDisablesLaunchAtLoginWithExplanation() async {
        launchAtLogin.status = .enabled
        let controller = makeController(launchStatus: .enabled)
        XCTAssertTrue(controller.isLaunchAtLoginEligible)

        await controller.setMenuBarVisible(false)

        XCTAssertFalse(controller.isLaunchAtLoginEligible)
        XCTAssertEqual(
            controller.launchAtLoginExplanation,
            AppPresenceController.launchAtLoginDisabledExplanation
        )
        // Verify launch at login was disabled on the platform
        XCTAssertEqual(launchAtLogin.status, .disabled)
        XCTAssertTrue(launchAtLogin.requestedValues.contains(false))
    }

    func testMenuBarRemainsVisibleWhenLaunchAtLoginCannotBeDisabled() async {
        launchAtLogin.failure = FakeLaunchAtLoginError.denied
        let controller = makeController(launchStatus: .enabled, storedMenuBarVisible: true)

        await controller.setMenuBarVisible(false)

        XCTAssertTrue(controller.isMenuBarVisible)
        XCTAssertTrue(defaults.bool(forKey: AppPresenceDefaultsKeys.isMenuBarVisible))
        XCTAssertEqual(controller.launchAtLoginStatus, .enabled)
        XCTAssertNotNil(controller.menuBarVisibilityError)
    }

    func testSettingLaunchAtLoginWhileIneligibleThrowsError() async {
        let controller = makeController()
        await controller.setMenuBarVisible(false)

        do {
            try await controller.setLaunchAtLoginEnabled(true)
            XCTFail("Expected setting launch at login while ineligible to throw")
        } catch let error as AppPresenceError {
            XCTAssertEqual(
                error,
                .launchAtLoginIneligible(AppPresenceController.launchAtLoginDisabledExplanation)
            )
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testAppPresencePreferenceUpdatesAreSerialized() async {
        launchAtLogin.status = .enabled
        launchAtLogin.shouldSuspendNextRequest = true
        let controller = makeController(launchStatus: .enabled)
        let hideTask = Task { @MainActor in
            await controller.setMenuBarVisible(false)
        }
        await Task.yield()

        XCTAssertTrue(controller.isChangingAppPresencePreference)
        do {
            try await controller.setLaunchAtLoginEnabled(false)
            XCTFail("Expected the overlapping preference update to be rejected")
        } catch let error as AppPresenceError {
            XCTAssertEqual(error, .preferenceUpdateInProgress)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        launchAtLogin.resumePendingRequest()
        await hideTask.value
        XCTAssertFalse(controller.isChangingAppPresencePreference)
        XCTAssertEqual(launchAtLogin.requestedValues, [false])
    }

    func testLaunchAtLoginCanBeEnabledAndDisabled() async throws {
        let controller = makeController()

        try await controller.setLaunchAtLoginEnabled(true)
        XCTAssertTrue(controller.isLaunchAtLoginSelected)
        XCTAssertEqual(launchAtLogin.requestedValues, [true])

        try await controller.setLaunchAtLoginEnabled(false)
        XCTAssertFalse(controller.isLaunchAtLoginSelected)
        XCTAssertEqual(launchAtLogin.requestedValues, [true, false])
    }

    func testRefreshingLaunchAtLoginStatusReadsExternalChanges() {
        let controller = makeController()
        launchAtLogin.status = .enabled

        controller.refreshLaunchAtLoginStatus()

        XCTAssertTrue(controller.isLaunchAtLoginSelected)
    }

    func testLaunchAtLoginFailureKeepsCurrentStateAndShowsAnError() async {
        launchAtLogin.failure = FakeLaunchAtLoginError.denied
        let controller = makeController()

        do {
            try await controller.setLaunchAtLoginEnabled(true)
            XCTFail("Expected Launch at Login to fail")
        } catch {
            XCTAssertEqual(controller.launchAtLoginStatus, .disabled)
            XCTAssertEqual(
                controller.launchAtLoginError,
                "macOS couldn't update Launch at Login. Registration was denied. Try again."
            )
        }
    }

    func testReenablingMenuBarRestoresLaunchAtLoginEligibility() async {
        let controller = makeController()
        await controller.setMenuBarVisible(false)
        XCTAssertFalse(controller.isLaunchAtLoginEligible)

        await controller.setMenuBarVisible(true)
        XCTAssertTrue(controller.isLaunchAtLoginEligible)
        XCTAssertNil(controller.launchAtLoginExplanation)
    }

    func testLaunchAtLoginRequiresApprovalPresentsExplanation() {
        let controller = makeController(launchStatus: .requiresApproval)

        XCTAssertTrue(controller.isLaunchAtLoginSelected)
        XCTAssertTrue(controller.isLaunchAtLoginEligible)
        XCTAssertEqual(
            controller.launchAtLoginExplanation,
            "Launch at Login requires approval in System Settings > General > Login Items."
        )
    }

    func testUnavailableLaunchAtLoginIsIneligible() {
        let controller = makeController(launchStatus: .unavailable)

        XCTAssertFalse(controller.isLaunchAtLoginSelected)
        XCTAssertFalse(controller.isLaunchAtLoginEligible)
        XCTAssertEqual(
            controller.launchAtLoginExplanation,
            "Launch at Login is unavailable for this copy of the app."
        )
    }

    func testRefreshingNotificationPermissionReadsThePlatform() async {
        platform.currentNotificationPermissionStatus = .denied
        let controller = makeController()

        await controller.refreshNotificationPermissionStatus()

        XCTAssertEqual(controller.notificationPermissionStatus, .denied)
    }

    // MARK: - 5. Workspace Health & Quitting
    func testWorkspaceHealthReportsHealthyWhenNoPersistenceError() {
        let controller = makeController(persistenceError: nil)
        XCTAssertEqual(controller.workspaceHealth, "My Mac: Healthy")
    }

    func testWorkspaceHealthReportsStorageUnavailableWhenErrorPresent() {
        let controller = makeController(persistenceError: "disk full")
        XCTAssertEqual(controller.workspaceHealth, "My Mac: Recovery storage unavailable")
    }

    func testQuittingAppTerminatesPlatform() {
        let controller = makeController()

        controller.quitApp()

        XCTAssertEqual(platform.terminateAppCallCount, 1)
    }
}

// MARK: - Test Doubles (Independent of AppKit internals)

@MainActor
final class FakeAppPresencePlatform: AppPresencePlatform {
    var activationPolicy: AppActivationPolicy = .accessory
    private(set) var activationPolicyChanges: [AppActivationPolicy] = []
    private(set) var activateAppCallCount: Int = 0
    private(set) var openMainWindowCallCount: Int = 0
    private(set) var focusMainWindowCallCount: Int = 0
    private(set) var terminateAppCallCount: Int = 0
    var currentNotificationPermissionStatus: NotificationPermissionStatus = .notDetermined

    func setActivationPolicy(_ policy: AppActivationPolicy) -> Bool {
        activationPolicy = policy
        activationPolicyChanges.append(policy)
        return true
    }

    func activateApp() {
        activateAppCallCount += 1
    }

    func openMainWindow() {
        openMainWindowCallCount += 1
    }

    func focusMainWindow() {
        focusMainWindowCallCount += 1
    }

    func terminateApp() {
        terminateAppCallCount += 1
    }

    func notificationPermissionStatus() async -> NotificationPermissionStatus {
        currentNotificationPermissionStatus
    }
}

@MainActor
final class FakeLaunchAtLoginPlatform: LaunchAtLoginPlatform {
    var status: LaunchAtLoginStatus
    private(set) var setEnabledCalled = false
    private(set) var requestedValues: [Bool] = []
    var failure: (any Error)?
    var shouldSuspendNextRequest = false
    private var pendingContinuation: CheckedContinuation<Void, Never>?

    init(status: LaunchAtLoginStatus = .disabled) {
        self.status = status
    }

    func setEnabled(_ enabled: Bool) async throws {
        setEnabledCalled = true
        requestedValues.append(enabled)
        if shouldSuspendNextRequest {
            shouldSuspendNextRequest = false
            await withCheckedContinuation { continuation in
                pendingContinuation = continuation
            }
        }
        if let failure {
            throw failure
        }
        status = enabled ? .enabled : .disabled
    }

    func resumePendingRequest() {
        pendingContinuation?.resume()
        pendingContinuation = nil
    }
}

private enum FakeLaunchAtLoginError: LocalizedError {
    case denied

    var errorDescription: String? {
        "Registration was denied."
    }
}

final class FakeAppPresenceDefaults: AppPresenceDefaults {
    private var storage: [String: Any] = [:]
    private(set) var removedKeys: [String] = []

    func bool(forKey defaultName: String) -> Bool {
        storage[defaultName] as? Bool ?? false
    }

    func set(_ value: Bool, forKey defaultName: String) {
        storage[defaultName] = value
    }

    func set(_ value: Any?, forKey defaultName: String) {
        storage[defaultName] = value
    }

    func object(forKey defaultName: String) -> Any? {
        storage[defaultName]
    }

    func persistedKeys() -> [String] {
        Array(storage.keys)
    }

    func removeObject(forKey defaultName: String) {
        storage.removeValue(forKey: defaultName)
        removedKeys.append(defaultName)
    }
}
