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
    private let defaults: AppPresenceDefaults
    private let runtime: (any WorkspaceRuntime)?
    private var runtimeStatusCancellable: AnyCancellable?

    @Published private(set) var isMainWindowOpen = false
    @Published private(set) var isMenuBarVisible: Bool
    @Published private(set) var isLaunchAtLoginEligible = true
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    @Published private(set) var launchAtLoginExplanation: String?
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var menuBarVisibilityError: String?
    @Published private(set) var notificationPermissionStatus: NotificationPermissionStatus = .notDetermined
    @Published private(set) var isChangingAppPresencePreference = false

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
        defaults: AppPresenceDefaults = UserDefaults.standard,
        runtime: (any WorkspaceRuntime)? = nil
    ) {
        self.platform = platform
        self.launchAtLoginPlatform = launchAtLoginPlatform
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
        if let status = runtime?.workspaceThemeStatus {
            if status.needsAttentionCount > 0 {
                return "My Mac: Needs attention (\(status.needsAttentionCount))"
            }
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

    func mainWindowDidClose() {
        isMainWindowOpen = false
        platform.setActivationPolicy(.accessory)
    }

    func openMainWindow() {
        if isMainWindowOpen {
            platform.focusMainWindow()
        } else {
            platform.openMainWindow()
            isMainWindowOpen = true
        }
        platform.setActivationPolicy(.regular)
        platform.activateApp()
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
        notificationPermissionStatus = await platform.notificationPermissionStatus()
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

    // MARK: - App Termination
    func quitApp() {
        platform.terminateApp()
    }
}
