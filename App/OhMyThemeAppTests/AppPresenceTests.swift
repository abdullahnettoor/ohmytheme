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
    private var notificationClient: FakeNotificationClient!
    private var defaults: FakeAppPresenceDefaults!
    private var runtime: FakeWorkspaceRuntime!

    override func setUp() async throws {
        try await super.setUp()
        platform = FakeAppPresencePlatform()
        launchAtLogin = FakeLaunchAtLoginPlatform(status: .disabled)
        notificationClient = FakeNotificationClient()
        defaults = FakeAppPresenceDefaults()
        runtime = FakeWorkspaceRuntime(workspace: .myMac)
    }

    private func makeController(
        launchStatus: LaunchAtLoginStatus = .disabled,
        storedMenuBarVisible: Bool? = nil,
        persistenceError: String? = nil,
        runtime customRuntime: FakeWorkspaceRuntime? = nil,
        notificationClient customNotificationClient: FakeNotificationClient? = nil
    ) -> AppPresenceController {
        if let storedMenuBarVisible {
            defaults.set(storedMenuBarVisible, forKey: AppPresenceDefaultsKeys.isMenuBarVisible)
        }
        let rt = customRuntime ?? FakeWorkspaceRuntime(
            workspace: .myMac,
            persistenceError: persistenceError
        )
        launchAtLogin.status = launchStatus
        let notif = customNotificationClient ?? notificationClient ?? FakeNotificationClient()
        return AppPresenceController(
            platform: platform,
            launchAtLoginPlatform: launchAtLogin,
            notificationClient: notif,
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
        notificationClient.permissionStatus = .denied
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

    func testWorkspaceHealthReportsNeedsAttentionWhenTargetsNeedAttention() {
        let fakeRuntime = FakeWorkspaceRuntime(workspace: .myMac)
        let outcome = TargetVerificationOutcome(
            targetInstanceID: TargetInstanceID(rawValue: "ghostty.default"),
            status: .needsAttention,
            detail: "Permission denied",
            verifiedAt: Date()
        )
        fakeRuntime.workspaceThemeStatus = WorkspaceThemeStatus(
            timestamp: Date(),
            desiredThemeAssignment: .fixed(variantID: "catppuccin/mocha"),
            targetOutcomes: [outcome]
        )
        let controller = makeController(runtime: fakeRuntime)
        XCTAssertEqual(controller.workspaceHealth, "My Mac: Needs attention (1)")
    }

    func testWorkspaceHealthReportsPendingWhenTargetsArePending() {
        let fakeRuntime = FakeWorkspaceRuntime(workspace: .myMac)
        let outcome = TargetVerificationOutcome(
            targetInstanceID: TargetInstanceID(rawValue: "ghostty.default"),
            status: .pending,
            verifiedAt: Date()
        )
        fakeRuntime.workspaceThemeStatus = WorkspaceThemeStatus(
            timestamp: Date(),
            desiredThemeAssignment: .fixed(variantID: "catppuccin/mocha"),
            targetOutcomes: [outcome]
        )
        let controller = makeController(runtime: fakeRuntime)
        XCTAssertEqual(controller.workspaceHealth, "My Mac: 1 pending")
    }

    // MARK: - 6. Notifications for Hidden Work (Issue #41)
    func testNotificationPermissionRequestedJustInTimeWhenWorkHidden() async {
        let controller = makeController(storedMenuBarVisible: false)
        controller.mainWindowDidOpen()
        XCTAssertEqual(notificationClient.requestAuthorizationCallCount, 0)

        controller.workDidStart()
        XCTAssertEqual(notificationClient.requestAuthorizationCallCount, 0)

        // Closing window while menu bar is hidden and work is active triggers just-in-time request
        let task = controller.mainWindowDidClose()
        _ = await task?.value

        XCTAssertEqual(notificationClient.requestAuthorizationCallCount, 1)
        XCTAssertEqual(controller.notificationPermissionStatus, .authorized)
    }

    func testNotificationPermissionRequestedWhenMenuBarHiddenWhileWorkAlreadyRunningInClosedWindow() async {
        let controller = makeController(storedMenuBarVisible: true)
        controller.workDidStart()
        XCTAssertEqual(notificationClient.requestAuthorizationCallCount, 0)

        // Menu bar is hidden while window is closed and work is running
        await controller.setMenuBarVisible(false)

        XCTAssertEqual(notificationClient.requestAuthorizationCallCount, 1)
        XCTAssertEqual(controller.notificationPermissionStatus, .authorized)
    }

    func testNotificationPermissionNotRequestedIfMenuBarIsVisible() async {
        let controller = makeController(storedMenuBarVisible: true)
        controller.mainWindowDidOpen()
        controller.workDidStart()

        let task = controller.mainWindowDidClose()
        _ = await task?.value

        XCTAssertEqual(notificationClient.requestAuthorizationCallCount, 0)
        XCTAssertEqual(controller.notificationPermissionStatus, .notDetermined)
    }

    func testNotificationPermissionNotRequestedIfNoWorkActive() async {
        let controller = makeController(storedMenuBarVisible: false)
        controller.mainWindowDidOpen()

        let task = controller.mainWindowDidClose()
        _ = await task?.value

        XCTAssertEqual(notificationClient.requestAuthorizationCallCount, 0)
    }

    func testPermissionDenialIsRespectedWithoutReprompting() async {
        notificationClient.requestAuthorizationResult = false
        let controller = makeController(storedMenuBarVisible: false)
        controller.mainWindowDidOpen()
        controller.workDidStart()

        let task = controller.mainWindowDidClose()
        _ = await task?.value

        XCTAssertEqual(notificationClient.requestAuthorizationCallCount, 1)
        XCTAssertEqual(controller.notificationPermissionStatus, .denied)

        // Next work start while hidden must not reprompt
        controller.workDidStart()
        XCTAssertEqual(notificationClient.requestAuthorizationCallCount, 1)

        // Work finishes with attention needed, but permission was denied -> no notifications posted
        let failureOutcome = TargetCapabilityOutcome(
            targetInstanceID: TargetInstanceID(rawValue: "ghostty.default"),
            adapterID: "ghostty",
            capabilityID: "connection",
            sourceType: .unavailable,
            sourceRevision: "n/a",
            configurationState: .failed,
            runningInstanceReach: .unavailable,
            detail: "Grant permissions"
        )
        let report = SetupReport(
            operationID: UUID(),
            outcomes: [failureOutcome]
        )
        await controller.workDidFinish(.setup(report))

        XCTAssertEqual(notificationClient.postedNotifications.count, 0)
    }

    func testSuccessfulHiddenWorkPostsNoNotification() async {
        notificationClient.permissionStatus = .authorized
        let controller = makeController(storedMenuBarVisible: false)
        controller.workDidStart()

        // Successful setup report
        let successOutcome = TargetCapabilityOutcome(
            targetInstanceID: TargetInstanceID(rawValue: "ghostty.default"),
            adapterID: "ghostty",
            capabilityID: "connection",
            sourceType: .upstream,
            sourceRevision: "1",
            configurationState: .updated,
            runningInstanceReach: .currentInstances,
            detail: "Installed"
        )
        let setupReport = SetupReport(
            operationID: UUID(),
            outcomes: [successOutcome]
        )
        await controller.workDidFinish(.setup(setupReport))

        XCTAssertEqual(notificationClient.postedNotifications.count, 0)

        // Successful apply report
        controller.workDidStart()
        let applyReport = DurableApplyReport(
            operationID: UUID(),
            variantID: "catppuccin/mocha",
            outcomes: []
        )
        await controller.workDidFinish(.apply(applyReport))

        XCTAssertEqual(notificationClient.postedNotifications.count, 0)
    }

    func testWorkFinishingWhileMainWindowOpenPostsNoNotification() async {
        notificationClient.permissionStatus = .authorized
        let controller = makeController(storedMenuBarVisible: false)
        controller.mainWindowDidOpen()
        controller.workDidStart()

        let failureOutcome = TargetCapabilityOutcome(
            targetInstanceID: TargetInstanceID(rawValue: "ghostty.default"),
            adapterID: "ghostty",
            capabilityID: "connection",
            sourceType: .unavailable,
            sourceRevision: "n/a",
            configurationState: .failed,
            runningInstanceReach: .unavailable,
            detail: "Grant permissions"
        )
        let setupReport = SetupReport(
            operationID: UUID(),
            outcomes: [failureOutcome]
        )
        await controller.workDidFinish(.setup(setupReport))

        // When main window is open, user sees it in-app; no notification should be posted
        XCTAssertEqual(notificationClient.postedNotifications.count, 0)
    }

    func testHiddenSetupNeedsAttentionPostsNotificationAndActionNavigatesToResults() async {
        notificationClient.permissionStatus = .authorized
        let controller = makeController(storedMenuBarVisible: false)
        let model = WorkspacePresentationModel(runtime: runtime)
        controller.presentationModel = model
        model.presenceController = controller

        controller.workDidStart()
        let failureOutcome = TargetCapabilityOutcome(
            targetInstanceID: TargetInstanceID(rawValue: "ghostty.default"),
            adapterID: "ghostty",
            capabilityID: "connection",
            sourceType: .unavailable,
            sourceRevision: "n/a",
            configurationState: .failed,
            runningInstanceReach: .unavailable,
            detail: "Grant permissions"
        )
        let setupReport = SetupReport(
            operationID: UUID(),
            outcomes: [failureOutcome]
        )
        await controller.workDidFinish(.setup(setupReport))

        XCTAssertEqual(notificationClient.postedNotifications.count, 1)
        let posted = notificationClient.postedNotifications[0]
        XCTAssertEqual(posted.title, "Setup Needs Attention")
        XCTAssertEqual(posted.targetState, .setupResults)

        // User clicks/activates notification action
        notificationClient.onNotificationAction?(posted.targetState)

        XCTAssertTrue(controller.isMainWindowOpen)
        XCTAssertEqual(platform.activationPolicy, .regular)
        XCTAssertEqual(platform.activateAppCallCount, 1)
        XCTAssertEqual(model.selectedSection, .apps)
    }

    func testHiddenApplyNeedsAttentionPostsNotificationAndActionNavigatesToOverview() async {
        notificationClient.permissionStatus = .authorized
        let controller = makeController(storedMenuBarVisible: false)
        let model = WorkspacePresentationModel(runtime: runtime)
        model.selectedSection = .themes
        controller.presentationModel = model
        model.presenceController = controller

        controller.workDidStart()
        let failedOutcome = TargetCapabilityOutcome(
            targetInstanceID: TargetInstanceID(rawValue: "ghostty.default"),
            adapterID: "ghostty",
            capabilityID: "theme",
            sourceType: .upstream,
            sourceRevision: "1",
            configurationState: .failed,
            runningInstanceReach: .unavailable,
            detail: "Check permissions"
        )
        let applyReport = DurableApplyReport(
            operationID: UUID(),
            variantID: "catppuccin/mocha",
            outcomes: [failedOutcome]
        )
        await controller.workDidFinish(.apply(applyReport))

        XCTAssertEqual(notificationClient.postedNotifications.count, 1)
        let posted = notificationClient.postedNotifications[0]
        XCTAssertEqual(posted.title, "Theme Apply Needs Attention")
        XCTAssertEqual(posted.targetState, .applyResults)

        notificationClient.onNotificationAction?(posted.targetState)

        XCTAssertTrue(controller.isMainWindowOpen)
        XCTAssertEqual(platform.activationPolicy, .regular)
        XCTAssertEqual(model.selectedSection, .overview)
    }

    func testNeedsAttentionDurableInWorkspaceHealthWhenNotificationsUnavailable() async {
        notificationClient.permissionStatus = .denied
        let fakeRuntime = FakeWorkspaceRuntime(workspace: .myMac)
        let failureOutcome = TargetCapabilityOutcome(
            targetInstanceID: TargetInstanceID(rawValue: "ghostty.default"),
            adapterID: "ghostty",
            capabilityID: "connection",
            sourceType: .unavailable,
            sourceRevision: "n/a",
            configurationState: .failed,
            runningInstanceReach: .unavailable,
            detail: "Grant permissions"
        )
        fakeRuntime.latestSetupReport = SetupReport(
            operationID: UUID(),
            outcomes: [failureOutcome]
        )
        let controller = makeController(
            storedMenuBarVisible: true,
            runtime: fakeRuntime
        )

        XCTAssertEqual(controller.workspaceHealth, "My Mac: Needs attention (1)")

        // Reopening main window
        controller.openMainWindow()
        XCTAssertTrue(controller.isMainWindowOpen)
    }

        func testQuittingAppTerminatesPlatform() {
        let controller = makeController()

        controller.quitApp()

        XCTAssertEqual(platform.terminateAppCallCount, 1)
    }
}

// MARK: - Test Doubles (Independent of AppKit internals)

@MainActor
final class FakeNotificationClient: NotificationClient {
    var permissionStatus: NotificationPermissionStatus
    var requestAuthorizationCallCount = 0
    var requestAuthorizationResult = true
    var postedNotifications: [PostedNotification] = []
    var onNotificationAction: ((NotificationTargetState?) -> Void)?

    init(permissionStatus: NotificationPermissionStatus = .notDetermined) {
        self.permissionStatus = permissionStatus
    }

    func requestAuthorization() async throws -> Bool {
        requestAuthorizationCallCount += 1
        let granted = requestAuthorizationResult
        permissionStatus = granted ? .authorized : .denied
        return granted
    }

    func postNotification(id: String, title: String, body: String, targetState: NotificationTargetState?) async throws {
        postedNotifications.append(PostedNotification(id: id, title: title, body: body, targetState: targetState))
    }
}

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
