import Foundation
import ThemeEngine
import ThemeModel

@MainActor
protocol WorkspaceRuntime: AnyObject {
    var workspace: Workspace { get }
    var themePacks: [ThemePack] { get }
    var persistenceError: String? { get }
    var canApplyThemes: Bool { get }

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
}

struct WorkspaceConnectionResult: Equatable {
    let snapshot: WorkspaceTargetSnapshot
    let report: ConnectionReport
}

struct WorkspaceSetupResult: Equatable {
    let snapshot: WorkspaceTargetSnapshot
    let report: SetupReport
}

extension WorkspaceRuntime {
    func apply(planID: UUID) async throws -> DurableApplyReport {
        try await apply(planID: planID, onProgress: nil)
    }
}
