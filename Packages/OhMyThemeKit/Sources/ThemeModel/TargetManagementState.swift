import Foundation

/// The user-facing lifecycle state of a target instance.
///
/// Lifecycle states:
/// - notSelected: Discovered and available, but not opted in.
/// - setupNeeded: Opted in, but one-time setup / connection has not yet completed.
/// - connected: Setup and ownership scope accepted; ready to follow theme assignments.
/// - needsAttention: Configuration drifted, broken, or needs user intervention.
/// - unavailable: Target application or context is not currently installed or reachable.
public enum TargetManagementState: String, Codable, Equatable, Sendable {
    case notSelected = "Not Selected"
    case setupNeeded = "Setup Needed"
    case connected = "Connected"
    case needsAttention = "Needs Attention"
    case unavailable = "Unavailable"
}
