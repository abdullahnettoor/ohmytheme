import ServiceManagement

public enum LaunchAtLoginStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

@MainActor
public protocol LaunchAtLoginPlatform: AnyObject {
    var status: LaunchAtLoginStatus { get }

    func setEnabled(_ enabled: Bool) async throws
}

@MainActor
public final class LaunchAtLoginClient: LaunchAtLoginPlatform {
    private let service: SMAppService

    public init() {
        service = .mainApp
    }

    public var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered:
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    public func setEnabled(_ enabled: Bool) async throws {
        if enabled {
            guard status == .disabled else { return }
            try service.register()
        } else {
            guard status == .enabled || status == .requiresApproval else { return }
            try await service.unregister()
        }
    }
}
