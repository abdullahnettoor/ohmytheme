import AppKit
import Foundation
import PlatformClients

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
    func presentMainWindow()
    func terminateApp()
    var notificationPermissionStatus: NotificationPermissionStatus { get }
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

    init() {}

    func setOpenWindowAction(_ action: @escaping () -> Void) {
        self.openWindowAction = action
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

    func presentMainWindow() {
        if let openWindowAction {
            openWindowAction()
        } else {
            let mainWindow = NSApplication.shared.windows.first { window in
                window.canBecomeMain && !(window is NSPanel)
            }
            if let mainWindow {
                mainWindow.makeKeyAndOrderFront(nil)
            }
        }
    }

    func terminateApp() {
        NSApplication.shared.terminate(nil)
    }

    var notificationPermissionStatus: NotificationPermissionStatus {
        .notDetermined
    }
}
