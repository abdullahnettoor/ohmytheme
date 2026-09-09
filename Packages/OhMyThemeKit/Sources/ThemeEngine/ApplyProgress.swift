import Foundation
import ThemeModel

/// Progress and live state of an Apply Transaction across its target instances.
public struct ApplyProgress: Codable, Equatable, Sendable {
    public enum StepStatus: Codable, Equatable, Sendable {
        case waiting
        case applying
        case completed(detail: String?)
        case skipped(detail: String)
        case failed(detail: String)
        case conflict(detail: String)
        case permissionRequired(detail: String)

        public var isCompleted: Bool {
            if case .completed = self { return true }
            return false
        }

        public var isFinished: Bool {
            switch self {
            case .waiting, .applying:
                return false
            case .completed, .skipped, .failed, .conflict, .permissionRequired:
                return true
            }
        }

        public var isActive: Bool {
            if case .applying = self { return true }
            return false
        }

        public var isSkipped: Bool {
            if case .skipped = self { return true }
            return false
        }
    }

    public struct TargetStep: Codable, Equatable, Identifiable, Sendable {
        public var id: TargetInstanceID { targetInstanceID }
        public let targetInstanceID: TargetInstanceID
        public let displayName: String
        public let adapterID: String
        public var status: StepStatus
        public var currentAction: String?

        public init(
            targetInstanceID: TargetInstanceID,
            displayName: String,
            adapterID: String,
            status: StepStatus = .waiting,
            currentAction: String? = nil
        ) {
            self.targetInstanceID = targetInstanceID
            self.displayName = displayName
            self.adapterID = adapterID
            self.status = status
            self.currentAction = currentAction
        }
    }

    public let operationID: UUID
    public var steps: [TargetStep]
    public var currentTargetID: TargetInstanceID?

    public init(
        operationID: UUID,
        steps: [TargetStep],
        currentTargetID: TargetInstanceID? = nil
    ) {
        self.operationID = operationID
        self.steps = steps
        self.currentTargetID = currentTargetID
    }

    public var finishedCount: Int {
        steps.filter { $0.status.isFinished }.count
    }

    /// Includes skipped and failed steps because progress measures terminal work.
    public var completedCount: Int { finishedCount }

    public var totalCount: Int {
        steps.count
    }

    public var fractionCompleted: Double {
        totalCount == 0 ? 1.0 : Double(finishedCount) / Double(totalCount)
    }

    public var isComplete: Bool {
        finishedCount == totalCount && totalCount > 0
    }

    public var activeStepName: String? {
        guard let currentTargetID else { return nil }
        return steps.first(where: { $0.targetInstanceID == currentTargetID })?.displayName
    }

    public var currentAction: String? {
        guard let currentTargetID else { return nil }
        return steps.first(where: { $0.targetInstanceID == currentTargetID })?.currentAction
    }
}
