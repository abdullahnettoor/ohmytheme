import Foundation
import Combine
import PlatformClients
import SwiftUI
import ThemeEngine
import ThemeModel

enum AppPresenceDefaultsKeys {
    static let isMenuBarVisible = "OhMyThemeMenuBarVisible"
}

enum AppPresenceError: LocalizedError, Equatable {
    case launchAtLoginIneligible(String)
    case preferenceUpdateInProgress

    var errorDescription: String? {
        switch self {
        case .launchAtLoginIneligible(let reason):
            return reason
        case .preferenceUpdateInProgress:
            return "Another app preference is still being updated."
        }
    }
}

@MainActor
final class AppPresenceController: ObservableObject {
    static let launchAtLoginDisabledExplanation =
        "Launch at Login is disabled while the menu bar item is hidden because Oh My Theme has no automatic background work."

    private let platform: AppPresencePlatform
    private let launchAtLoginPlatform: LaunchAtLoginPlatform
    private let notificationClient: any NotificationClient
    private let defaults: AppPresenceDefaults
    private let runtime: (any WorkspaceRuntime)?
    private var runtimeStatusCancellable: AnyCancellable?

    weak var presentationModel: WorkspacePresentationModel?

    @Published private(set) var isMainWindowOpen = false
    @Published private(set) var isMenuBarVisible: Bool
    @Published private(set) var isLaunchAtLoginEligible = true
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    @Published private(set) var launchAtLoginExplanation: String?
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var menuBarVisibilityError: String?
    @Published private(set) var notificationPermissionStatus: NotificationPermissionStatus = .notDetermined
    @Published private(set) var isChangingAppPresencePreference = false
    @Published private(set) var isWorkActive = false

    var isMenuBarVisibleBinding: Binding<Bool> {
        Binding(
            get: { self.isMenuBarVisible },
            set: { newValue in
                Task {
                    await self.setMenuBarVisible(newValue)
                }
            }
        )
    }

    init(
        platform: AppPresencePlatform,
        launchAtLoginPlatform: LaunchAtLoginPlatform,
        notificationClient: (any NotificationClient)? = nil,
        defaults: AppPresenceDefaults = UserDefaults.standard,
        runtime: (any WorkspaceRuntime)? = nil
    ) {
        self.platform = platform
        self.launchAtLoginPlatform = launchAtLoginPlatform
        let resolvedNotificationClient = notificationClient ?? ProductionNotificationClient()
        self.notificationClient = resolvedNotificationClient
        self.defaults = defaults
        self.runtime = runtime
        self.launchAtLoginStatus = launchAtLoginPlatform.status

        if defaults.object(forKey: AppPresenceDefaultsKeys.isMenuBarVisible) != nil {
            self.isMenuBarVisible = defaults.bool(forKey: AppPresenceDefaultsKeys.isMenuBarVisible)
        } else {
            self.isMenuBarVisible = true
        }

        if !self.isMenuBarVisible,
            launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
        {
            self.isMenuBarVisible = true
            defaults.set(true, forKey: AppPresenceDefaultsKeys.isMenuBarVisible)
            self.menuBarVisibilityError =
                "The menu bar item was restored because Launch at Login is active. Turn off Launch at Login before hiding it."
        }

        updateLaunchAtLoginEligibility()

        if self.isMenuBarVisible {
            MenuBarPresence.clearHiddenStatusItemPreferences(in: defaults)
        }

        self.notificationClient.onNotificationAction = { [weak self] targetState in
            self?.openMainWindow(navigatingTo: targetState)
        }

        runtimeStatusCancellable = runtime?.workspaceStatusPublisher.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    var activationPolicy: AppActivationPolicy {
        platform.activationPolicy
    }

    var isLaunchAtLoginSelected: Bool {
        launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
    }

    var workspaceHealth: String {
        if runtime?.persistenceError != nil {
            return "My Mac: Recovery storage unavailable"
        }
        if runtime?.unresolvedRecovery != nil {
            return "My Mac: Needs attention (recovery required)"
        }
        var targetsNeedingAttention = Set<TargetInstanceID>()
        if let setupOutcomes = runtime?.latestSetupReport?.unresolvedOutcomes {
            for outcome in setupOutcomes {
                targetsNeedingAttention.insert(outcome.targetInstanceID)
            }
        }
        if let status = runtime?.workspaceThemeStatus {
            for outcome in status.targetOutcomes where outcome.status == .needsAttention {
                targetsNeedingAttention.insert(outcome.targetInstanceID)
            }
        }
        let setupAttentionCount = runtime?.latestSetupReport?.unresolvedOutcomes.count ?? 0
        let themeAttentionCount = runtime?.workspaceThemeStatus?.needsAttentionCount ?? 0
        let totalAttentionCount = targetsNeedingAttention.isEmpty
            ? max(themeAttentionCount, setupAttentionCount)
            : targetsNeedingAttention.count
        if totalAttentionCount > 0 {
            return "My Mac: Needs attention (\(totalAttentionCount))"
        }
        if let status = runtime?.workspaceThemeStatus {
            if status.pendingCount > 0 {
                return "My Mac: \(status.pendingCount) pending"
            }
            return "My Mac: Healthy"
        }
        return "My Mac: Healthy"
    }

    // MARK: - Window Lifecycle
    func mainWindowDidOpen() {
        isMainWindowOpen = true
        refreshLaunchAtLoginStatus()
        platform.setActivationPolicy(.regular)
        platform.activateApp()
    }

    @discardableResult
    func mainWindowDidClose() -> Task<Bool, Never>? {
        isMainWindowOpen = false
        platform.setActivationPolicy(.accessory)
        if !isMenuBarVisible && isWorkActive {
            return Task {
                await requestNotificationPermissionJustInTimeIfNeeded()
            }
        }
        return nil
    }

    func openMainWindow(navigatingTo targetState: NotificationTargetState? = nil) {
        if isMainWindowOpen {
            platform.focusMainWindow()
        } else {
            platform.openMainWindow()
            isMainWindowOpen = true
        }
        platform.setActivationPolicy(.regular)
        platform.activateApp()

        if let targetState {
            presentationModel?.navigateTo(targetState: targetState)
        }
    }

    @discardableResult
    func handleReopen(hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows {
            isMainWindowOpen = true
        }
        openMainWindow()
        return true
    }

    // MARK: - Menu Bar Visibility
    func setMenuBarVisible(_ visible: Bool) async {
        guard !isChangingAppPresencePreference else { return }
        isChangingAppPresencePreference = true
        menuBarVisibilityError = nil
        defer { isChangingAppPresencePreference = false }

        if !visible,
            launchAtLoginPlatform.status == .enabled || launchAtLoginPlatform.status == .requiresApproval
        {
            do {
                try await launchAtLoginPlatform.setEnabled(false)
                refreshLaunchAtLoginStatus()
            } catch {
                refreshLaunchAtLoginStatus()
                menuBarVisibilityError =
                    "Oh My Theme couldn't hide the menu bar item because macOS couldn't disable Launch at Login. \(error.localizedDescription)"
                return
            }

            guard launchAtLoginStatus == .disabled else {
                menuBarVisibilityError =
                    "Oh My Theme couldn't hide the menu bar item because Launch at Login is still active. Try again."
                return
            }
        }

        isMenuBarVisible = visible
        defaults.set(visible, forKey: AppPresenceDefaultsKeys.isMenuBarVisible)

        if visible {
            MenuBarPresence.clearHiddenStatusItemPreferences(in: defaults)
        } else if isWorkActive && !isMainWindowOpen {
            await requestNotificationPermissionJustInTimeIfNeeded()
        }
        updateLaunchAtLoginEligibility()
    }

    // MARK: - Launch at Login
    func setLaunchAtLoginEnabled(_ enabled: Bool) async throws {
        guard !isChangingAppPresencePreference else {
            throw AppPresenceError.preferenceUpdateInProgress
        }
        isChangingAppPresencePreference = true
        launchAtLoginError = nil
        defer { isChangingAppPresencePreference = false }

        guard isLaunchAtLoginEligible else {
            throw AppPresenceError.launchAtLoginIneligible(
                launchAtLoginExplanation ?? Self.launchAtLoginDisabledExplanation
            )
        }
        do {
            try await launchAtLoginPlatform.setEnabled(enabled)
            refreshLaunchAtLoginStatus()
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginError =
                "macOS couldn't update Launch at Login. \(error.localizedDescription) Try again."
            throw error
        }
    }

    func refreshNotificationPermissionStatus() async {
        notificationPermissionStatus = await notificationClient.permissionStatus
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = launchAtLoginPlatform.status
        updateLaunchAtLoginEligibility()
    }

    private func updateLaunchAtLoginEligibility() {
        if !isMenuBarVisible {
            isLaunchAtLoginEligible = false
            launchAtLoginExplanation = Self.launchAtLoginDisabledExplanation
        } else if launchAtLoginStatus == .unavailable {
            isLaunchAtLoginEligible = false
            launchAtLoginExplanation = "Launch at Login is unavailable for this copy of the app."
        } else {
            isLaunchAtLoginEligible = true
            if launchAtLoginStatus == .requiresApproval {
                launchAtLoginExplanation =
                    "Launch at Login requires approval in System Settings > General > Login Items."
            } else {
                launchAtLoginExplanation = nil
            }
        }
    }

    // MARK: - Work Lifecycle & Notifications

    func workDidStart() {
        isWorkActive = true
        if !isMenuBarVisible && !isMainWindowOpen {
            Task {
                await requestNotificationPermissionJustInTimeIfNeeded()
            }
        }
    }

    @discardableResult
    func requestNotificationPermissionJustInTimeIfNeeded() async -> Bool {
        guard !isMenuBarVisible else { return false }
        guard isWorkActive else { return false }
        let currentStatus = await notificationClient.permissionStatus
        notificationPermissionStatus = currentStatus
        guard currentStatus == .notDetermined else { return false }
        do {
            let granted = try await notificationClient.requestAuthorization()
            notificationPermissionStatus = granted ? .authorized : .denied
            return granted
        } catch {
            notificationPermissionStatus = .denied
            return false
        }
    }

    enum HiddenWorkResult {
        case setup(SetupReport)
        case apply(DurableApplyReport)
        case setupFailed(Error)
        case applyFailed(Error)
        case preflightPaused(ApplyPlan)
    }

    func workDidFinish(_ result: HiddenWorkResult) async {
        isWorkActive = false

        guard !isMainWindowOpen, !isMenuBarVisible else { return }

        let needsAttention: Bool
        let title: String
        let body: String
        let targetState: NotificationTargetState

        switch result {
        case .setup(let report):
            let unresolved = report.unresolvedOutcomes
            if unresolved.isEmpty {
                needsAttention = false
                title = ""
                body = ""
                targetState = .setupResults
            } else {
                needsAttention = true
                title = "Setup Needs Attention"
                body = unresolved.count == 1
                    ? "1 target requires attention to complete setup."
                    : "\(unresolved.count) targets require attention to complete setup."
                targetState = .setupResults
            }
        case .setupFailed(let error):
            needsAttention = true
            title = "Setup Failed"
            body = error.localizedDescription
            targetState = .setupResults
        case .apply(let report):
            let attentionOutcomes = report.outcomes.filter { outcome in
                switch outcome.configurationState {
                case .permissionRequired, .conflicted, .failed:
                    return true
                case .updated, .unchanged, .unavailable:
                    return outcome.rollbackState == .recoveryRequired
                }
            }
            let themeAttentionCount = runtime?.workspaceThemeStatus?.needsAttentionCount ?? 0
            let hasRecovery = runtime?.unresolvedRecovery != nil

            if attentionOutcomes.isEmpty && themeAttentionCount == 0 && !hasRecovery {
                needsAttention = false
                title = ""
                body = ""
                targetState = .applyResults
            } else {
                needsAttention = true
                title = "Theme Apply Needs Attention"
                if hasRecovery {
                    body = "A target encountered a failure requiring recovery."
                    targetState = .recovery
                } else if !attentionOutcomes.isEmpty {
                    let count = attentionOutcomes.count
                    let hasPermission = attentionOutcomes.contains { $0.configurationState == .permissionRequired }
                    let hasConflict = attentionOutcomes.contains { $0.configurationState == .conflicted }
                    if hasPermission {
                        body = count == 1
                            ? "1 target requires permission to apply the theme."
                            : "\(count) targets require permission or attention."
                    } else if hasConflict {
                        body = count == 1
                            ? "1 target has a conflicting configuration."
                            : "\(count) targets require conflict resolution or attention."
                    } else {
                        body = count == 1
                            ? "1 target failed to apply the desired theme."
                            : "\(count) targets failed to apply the desired theme."
                    }
                    targetState = .applyResults
                } else {
                    body = themeAttentionCount == 1
                        ? "1 target requires attention."
                        : "\(themeAttentionCount) targets require attention."
                    targetState = .applyResults
                }
            }
        case .applyFailed(let error):
            needsAttention = true
            title = "Theme Apply Failed"
            body = error.localizedDescription
            targetState = .applyResults
        case .preflightPaused(let plan):
            needsAttention = true
            title = "Theme Apply Paused"
            let explanation = plan.preflightExplanation(acknowledgedUnavailableTargets: [])
            body = explanation ?? "Review required before applying changes."
            targetState = .preflightReview
        }

        guard needsAttention else { return }

        let currentPermission = await notificationClient.permissionStatus
        notificationPermissionStatus = currentPermission
        guard currentPermission == .authorized || currentPermission == .provisional else {
            return
        }

        try? await notificationClient.postNotification(
            id: UUID().uuidString,
            title: title,
            body: body,
            targetState: targetState
        )
    }

    // MARK: - Reset
    /// Restores presentation defaults ahead of a Reset quit: the menu bar item
    /// returns, remembered hidden status-item preferences are cleared, and
    /// Launch at Login is disabled. Returns whether presentation cleanup
    /// finished; Reset must not quit while Launch at Login is still enabled.
    @discardableResult
    func resetPresentationDefaultsForReset() async -> Bool {
        guard !isChangingAppPresencePreference else { return false }
        isChangingAppPresencePreference = true
        defer { isChangingAppPresencePreference = false }

        isMenuBarVisible = true
        defaults.set(true, forKey: AppPresenceDefaultsKeys.isMenuBarVisible)
        MenuBarPresence.clearHiddenStatusItemPreferences(in: defaults)
        menuBarVisibilityError = nil
        do {
            try await launchAtLoginPlatform.setEnabled(false)
        } catch {
            launchAtLoginError =
                "macOS couldn't disable Launch at Login during Reset. \(error.localizedDescription)"
            refreshLaunchAtLoginStatus()
            return false
        }
        refreshLaunchAtLoginStatus()
        return true
    }

    // MARK: - App Termination
    func quitApp() {
        platform.terminateApp()
    }
}
