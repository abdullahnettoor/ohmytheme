import Foundation

/// The verified state of a Connected Target Instance relative to the desired Theme Assignment.
public enum TargetVerificationStatus: String, Codable, Equatable, Sendable {
    /// The target instance verified as matching the desired theme assignment.
    case applied
    /// The target instance has not yet been applied to the desired theme assignment.
    case pending
    /// The target instance encountered an error, conflict, or required permission needing user attention.
    case needsAttention
}

/// The timestamped outcome of verifying a specific target instance against a desired Theme Assignment.
public struct TargetVerificationOutcome: Codable, Equatable, Sendable, Identifiable {
    public var id: TargetInstanceID { targetInstanceID }
    public let targetInstanceID: TargetInstanceID
    public let status: TargetVerificationStatus
    public let detail: String?
    public let verifiedVariantID: String?
    public let verifiedAt: Date

    public init(
        targetInstanceID: TargetInstanceID,
        status: TargetVerificationStatus,
        detail: String? = nil,
        verifiedVariantID: String? = nil,
        verifiedAt: Date = Date()
    ) {
        self.targetInstanceID = targetInstanceID
        self.status = status
        self.detail = detail
        self.verifiedVariantID = verifiedVariantID
        self.verifiedAt = verifiedAt
    }
}

/// A timestamped summary that compares a Workspace's desired Theme Assignment
/// with the latest verified state of each connected target instance.
public struct WorkspaceThemeStatus: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let desiredThemeAssignment: ThemeAssignment?
    public let targetOutcomes: [TargetVerificationOutcome]

    public var appliedCount: Int {
        targetOutcomes.filter { $0.status == .applied }.count
    }

    public var pendingCount: Int {
        targetOutcomes.filter { $0.status == .pending }.count
    }

    public var needsAttentionCount: Int {
        targetOutcomes.filter { $0.status == .needsAttention }.count
    }

    public var totalTargetCount: Int {
        targetOutcomes.count
    }

    public var isFullyApplied: Bool {
        !targetOutcomes.isEmpty && pendingCount == 0 && needsAttentionCount == 0
    }

    public init(
        timestamp: Date = Date(),
        desiredThemeAssignment: ThemeAssignment?,
        targetOutcomes: [TargetVerificationOutcome]
    ) {
        self.timestamp = timestamp
        self.desiredThemeAssignment = desiredThemeAssignment
        self.targetOutcomes = targetOutcomes
    }
}
