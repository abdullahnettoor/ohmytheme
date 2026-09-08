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
    func reviewConnection(optionID: TargetInstanceID) async throws -> ConnectionPlan
    func connect(
        optionID: TargetInstanceID,
        reviewedPlan: ConnectionPlan
    ) async throws -> WorkspaceConnectionResult
    func restoreAndDisconnect(
        targetInstanceID: TargetInstanceID
    ) async throws -> WorkspaceConnectionResult
    func prepareApplyPlan() async throws -> ApplyPlan
    func apply(planID: UUID) async throws -> DurableApplyReport
    func undoLast() async throws -> UndoReport
    func undoAvailability() async throws -> UndoAvailability
}

struct WorkspaceTargetSnapshot: Equatable {
    let workspace: Workspace
    let targets: [WorkspaceMenuModel.ApplicationTarget]
}

struct WorkspaceConnectionResult: Equatable {
    let snapshot: WorkspaceTargetSnapshot
    let report: ConnectionReport
}
