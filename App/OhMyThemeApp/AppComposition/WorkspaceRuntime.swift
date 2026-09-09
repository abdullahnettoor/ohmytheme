import Combine
import Foundation
import ThemeEngine
import ThemeModel

@MainActor
protocol WorkspaceRuntime: AnyObject, ObservableObject {
    var workspace: Workspace { get }
    var themePacks: [ThemePack] { get }
    var persistenceError: String? { get }
    var canApplyThemes: Bool { get }
    var onboardingDisposition: OnboardingDisposition { get }
    func updateOnboardingDisposition(_ disposition: OnboardingDisposition) async throws

    var workspaceThemeStatus: WorkspaceThemeStatus? { get }
    var unresolvedRecovery: String? { get }
    var latestSetupReport: SetupReport? { get }
    var latestApplyReport: DurableApplyReport? { get }
    var workspaceStatusPublisher: AnyPublisher<Void, Never> { get }

    func verifyThemeStatus() async throws -> WorkspaceThemeStatus
    func selectFixedThemeVariant(_ variantID: String)
    func start() async throws -> WorkspaceTargetSnapshot
    func refreshTargets() async throws -> WorkspaceTargetSnapshot
    func reviewConnection(optionID: TargetInstanceID) async throws -> ConnectionPlan
    func connect(
        optionID: TargetInstanceID,
        reviewedPlan: ConnectionPlan
    ) async throws -> WorkspaceConnectionResult
    func restoreAndDisconnect(
        targetInstanceID: TargetInstanceID
    ) async throws -> WorkspaceConnectionResult
    func reviewDisconnect(targetInstanceID: TargetInstanceID) async throws -> DisconnectReview
    func relinquishManagement(
        targetInstanceID: TargetInstanceID
    ) async throws -> WorkspaceRelinquishResult
    func reviewReset() async throws -> ResetReview
    func finalizeReset() async throws -> WorkspaceTargetSnapshot
    func prepareSetupPlan(retrySourceOperationID: UUID?) async throws -> SetupPlan
    func validateSetupPlanPreconditions(_ plan: SetupPlan) async -> SetupPlanPreconditionValidation
    func cancelRemainingSetup(operationID: UUID) async throws
    func cancelRemainingApply(operationID: UUID) async throws
    func executeSetupPlan(
        _ plan: SetupPlan,
        onProgress: (@Sendable (SetupProgress) -> Void)?
    ) async throws -> WorkspaceSetupResult
    func prepareApplyPlan() async throws -> ApplyPlan
    func apply(
        planID: UUID,
        targetInstanceIDs: Set<TargetInstanceID>?,
        onProgress: (@Sendable (ApplyProgress) -> Void)?
    ) async throws -> DurableApplyReport
    func undoLast() async throws -> UndoReport
    func undoAvailability() async throws -> UndoAvailability

    func setTargetOptIn(
        instanceID: TargetInstanceID,
        isOptedIn: Bool
    ) async throws -> WorkspaceTargetSnapshot
    func selectAllRecommended() async throws -> WorkspaceTargetSnapshot
    func selectRecommended(
        applicationID: String
    ) async throws -> WorkspaceTargetSnapshot
}

struct WorkspaceTargetSnapshot: Equatable {
    let workspace: Workspace
    let targets: [WorkspacePresentationModel.ApplicationTarget]
    let replacementSuggestions: [ConnectionReplacementSuggestion]

    init(
        workspace: Workspace,
        targets: [WorkspacePresentationModel.ApplicationTarget],
        replacementSuggestions: [ConnectionReplacementSuggestion] = []
    ) {
        self.workspace = workspace
        self.targets = targets
        self.replacementSuggestions = replacementSuggestions
    }
}

/// A newly discovered Target Instance that may replace a Connected Target
/// Instance which disappeared from discovery. Suggestions never opt in,
/// connect, or transfer state; connecting a replacement follows the normal
/// fresh Setup Plan and Setup Transaction rules.
struct ReplacementCandidate: Equatable {
    let id: TargetInstanceID
    let displayName: String
}

/// A reviewed Connection Replacement suggestion: a missing Connected Target
/// Instance retains its own identity, opt-in, baseline, and recovery state
/// while a related newly discovered instance is offered as a separate,
/// not-selected candidate. No Target Opt-in, Connection Baseline, identity,
/// Configuration Ownership, or external state transfers automatically.
struct ConnectionReplacementSuggestion: Equatable {
    let oldInstance: ConnectedTargetInstance
    let newCandidates: [ReplacementCandidate]
    let oldBaselineCapturedAt: Date?
}

struct WorkspaceConnectionResult: Equatable {
    let snapshot: WorkspaceTargetSnapshot
    let report: ConnectionReport
}

struct WorkspaceRelinquishResult: Equatable {
    let snapshot: WorkspaceTargetSnapshot
    let report: RelinquishReport
}

/// A reviewed Reset plan covering every Connected Target Instance. Safe
/// entries restore their Connection Baselines; conflicting entries require
/// explicit Management Relinquishment or remain unresolved and block Reset.
/// Recovery records and restoration content are retained until each target
/// reaches a safe terminal state.
struct ResetReview: Equatable {
    let entries: [DisconnectReview]

    /// True when no Connected Target Instance remains to resolve.
    var canComplete: Bool { entries.isEmpty }

    /// True when at least one entry needs Management Relinquishment.
    var hasConflicts: Bool { entries.contains { !$0.isSafeToRestore } }
}

struct WorkspaceSetupResult: Equatable {
    let snapshot: WorkspaceTargetSnapshot
    let report: SetupReport
}

extension WorkspaceRuntime {
    func apply(planID: UUID) async throws -> DurableApplyReport {
        try await apply(planID: planID, targetInstanceIDs: nil, onProgress: nil)
    }

    func apply(
        planID: UUID,
        onProgress: (@Sendable (ApplyProgress) -> Void)?
    ) async throws -> DurableApplyReport {
        try await apply(planID: planID, targetInstanceIDs: nil, onProgress: onProgress)
    }
}
