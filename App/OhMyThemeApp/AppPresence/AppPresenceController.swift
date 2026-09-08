import Foundation
import SwiftUI
import PlatformClients
import ThemeEngine
import ThemeModel

enum AppPresenceDefaultsKeys {
    static let isMenuBarVisible = "OhMyThemeMenuBarVisible"
}

enum AppPresenceError: LocalizedError, Equatable {
    case launchAtLoginIneligible(String)

    var errorDescription: String? {
        switch self {
        case .launchAtLoginIneligible(let reason):
            return reason
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

    @Published private(set) var isMainWindowOpen: Bool = false
    @Published private(set) var openMainWindowCount: Int = 0
    @Published private(set) var isMenuBarVisible: Bool
    @Published private(set) var isLaunchAtLoginEligible: Bool = true
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    @Published private(set) var launchAtLoginExplanation: String?
    @Published private(set) var notificationPermissionStatus: NotificationPermissionStatus

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
        self.notificationPermissionStatus = platform.notificationPermissionStatus

        if defaults.object(forKey: AppPresenceDefaultsKeys.isMenuBarVisible) != nil {
            self.isMenuBarVisible = defaults.bool(forKey: AppPresenceDefaultsKeys.isMenuBarVisible)
        } else {
            self.isMenuBarVisible = true
        }

        updateLaunchAtLoginEligibility()

        if self.isMenuBarVisible {
            MenuBarPresence.clearHiddenStatusItemPreferences(in: defaults)
        }
    }

    var activationPolicy: AppActivationPolicy {
        platform.activationPolicy
    }

    var workspaceHealth: String {
        if runtime?.persistenceError != nil {
            return "My Mac: Recovery storage unavailable"
        }
        return "My Mac: Healthy"
    }

    // MARK: - Window Lifecycle
    func mainWindowDidOpen() {
        openMainWindowCount += 1
        isMainWindowOpen = true
        platform.setActivationPolicy(.regular)
        platform.activateApp()
    }

    func mainWindowDidClose() {
        openMainWindowCount = max(0, openMainWindowCount - 1)
        if openMainWindowCount == 0 {
            isMainWindowOpen = false
            platform.setActivationPolicy(.accessory)
        }
    }

    func openMainWindow() {
        platform.presentMainWindow()
        if !isMainWindowOpen {
            isMainWindowOpen = true
            platform.setActivationPolicy(.regular)
            platform.activateApp()
        }
    }

    @discardableResult
    func handleReopen(hasVisibleWindows: Bool) -> Bool {
        openMainWindow()
        return true
    }

    // MARK: - Menu Bar Visibility
    func setMenuBarVisible(_ visible: Bool) async {
        isMenuBarVisible = visible
        defaults.set(visible, forKey: AppPresenceDefaultsKeys.isMenuBarVisible)

        if !visible {
            if launchAtLoginPlatform.status == .enabled || launchAtLoginPlatform.status == .requiresApproval {
                try? await launchAtLoginPlatform.setEnabled(false)
                refreshLaunchAtLoginStatus()
            }
            updateLaunchAtLoginEligibility()
        } else {
            MenuBarPresence.clearHiddenStatusItemPreferences(in: defaults)
            updateLaunchAtLoginEligibility()
        }
    }

    // MARK: - Launch at Login
    func setLaunchAtLoginEnabled(_ enabled: Bool) async throws {
        guard isLaunchAtLoginEligible else {
            throw AppPresenceError.launchAtLoginIneligible(
                launchAtLoginExplanation ?? Self.launchAtLoginDisabledExplanation
            )
        }
        try await launchAtLoginPlatform.setEnabled(enabled)
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = launchAtLoginPlatform.status
        updateLaunchAtLoginEligibility()
    }

    private func updateLaunchAtLoginEligibility() {
        if !isMenuBarVisible {
            isLaunchAtLoginEligible = false
            launchAtLoginExplanation = Self.launchAtLoginDisabledExplanation
        } else {
            isLaunchAtLoginEligible = true
            if launchAtLoginStatus == .requiresApproval {
                launchAtLoginExplanation = "Launch at Login requires approval in System Settings > General > Login Items."
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
