import Foundation
import UserNotifications

enum NotificationTargetState: String, Codable, Equatable, Sendable {
    case setupResults
    case applyResults
    case recovery
    case preflightReview
}

struct PostedNotification: Equatable, Sendable {
    let id: String
    let title: String
    let body: String
    let targetState: NotificationTargetState?

    init(id: String, title: String, body: String, targetState: NotificationTargetState?) {
        self.id = id
        self.title = title
        self.body = body
        self.targetState = targetState
    }
}

@MainActor
protocol NotificationClient: AnyObject {
    var permissionStatus: NotificationPermissionStatus { get async }
    func requestAuthorization() async throws -> Bool
    func postNotification(id: String, title: String, body: String, targetState: NotificationTargetState?) async throws
    var onNotificationAction: ((NotificationTargetState?) -> Void)? { get set }
}

@MainActor
final class ProductionNotificationClient: NSObject, NotificationClient, UNUserNotificationCenterDelegate {
    var onNotificationAction: ((NotificationTargetState?) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    var permissionStatus: NotificationPermissionStatus {
        get async {
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

    func requestAuthorization() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        return try await center.requestAuthorization(options: [.alert, .sound])
    }

    func postNotification(id: String, title: String, body: String, targetState: NotificationTargetState?) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let targetState {
            content.userInfo = ["targetState": targetState.rawValue]
        }

        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil
        )
        try await UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let rawState = userInfo["targetState"] as? String
        let targetState = rawState.flatMap { NotificationTargetState(rawValue: $0) }
        Task { @MainActor in
            self.onNotificationAction?(targetState)
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
