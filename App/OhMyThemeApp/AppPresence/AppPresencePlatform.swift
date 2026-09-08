import AppKit
import Foundation
import PlatformClients
import UserNotifications

enum AppActivationPolicy: Equatable {
    case regular
    case accessory
    case prohibited
}

enum NotificationPermissionStatus: String, Equatable {
    case notDetermined = "Not Determined"
    case authorized = "Authorized"
    case denied = "Denied"
    case provisional = "Provisional"
}

@MainActor
protocol AppPresencePlatform: AnyObject {
    var activationPolicy: AppActivationPolicy { get }
    @discardableResult
    func setActivationPolicy(_ policy: AppActivationPolicy) -> Bool
    func activateApp()
    func openMainWindow()
    func focusMainWindow()
    func terminateApp()
    func notificationPermissionStatus() async -> NotificationPermissionStatus
}

protocol AppPresenceDefaults: AnyObject, MenuBarVisibilityDefaults {
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Bool, forKey defaultName: String)
    func set(_ value: Any?, forKey defaultName: String)
    func object(forKey defaultName: String) -> Any?
}

extension UserDefaults: AppPresenceDefaults {}

@MainActor
final class ProductionAppPresencePlatform: AppPresencePlatform {
    private var openWindowAction: (() -> Void)?
    private weak var mainWindow: NSWindow?

    init() {}

    func setOpenWindowAction(_ action: @escaping () -> Void) {
        self.openWindowAction = action
    }

    func setMainWindow(_ window: NSWindow?) {
        mainWindow = window
    }

    var activationPolicy: AppActivationPolicy {
        switch NSApplication.shared.activationPolicy() {
        case .regular:
            return .regular
        case .accessory:
            return .accessory
        case .prohibited:
            return .prohibited
        @unknown default:
            return .accessory
        }
    }

    @discardableResult
    func setActivationPolicy(_ policy: AppActivationPolicy) -> Bool {
        let nsPolicy: NSApplication.ActivationPolicy
        switch policy {
        case .regular:
            nsPolicy = .regular
        case .accessory:
            nsPolicy = .accessory
        case .prohibited:
            nsPolicy = .prohibited
        }
        return NSApplication.shared.setActivationPolicy(nsPolicy)
    }

    func activateApp() {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func openMainWindow() {
        openWindowAction?()
    }

    func focusMainWindow() {
        guard let mainWindow else {
            openMainWindow()
            return
        }
        mainWindow.makeKeyAndOrderFront(nil)
    }

    func terminateApp() {
        NSApplication.shared.terminate(nil)
    }

    func notificationPermissionStatus() async -> NotificationPermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        @unknown default:
            return .notDetermined
        }
    }
}
