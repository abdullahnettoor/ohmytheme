import Combine
import Foundation
import ThemeEngine
import ThemeModel

@MainActor
final class WorkspacePresentationModel: ObservableObject {
    enum ReportKind: Equatable {
        case apply
        case undo
        case connection
        case disconnect
    }

    struct ApplicationTarget: Equatable, Identifiable {
        enum State: String, Equatable {
            case connected = "Connected"
            case setupNeeded = "Setup Needed"
            case unavailable = "Unavailable"
        }

        let id: String
        let name: String
        let systemImage: String
        let state: State
        let summary: String
        let instanceDetails: [String]
        let connectionOptions: [ConnectionOption]

        var showsInstanceDetails: Bool {
            state == .unavailable || connectionOptions.count > 1
        }

        var showsConnectionOptionDetails: Bool {
            state == .unavailable || connectionOptions.count > 1
        }
    }

    struct ConnectionOption: Equatable, Identifiable {
        let id: TargetInstanceID
        let name: String
        let detail: String?
        let permissionDisclosure: String?

        init(
            id: TargetInstanceID,
            name: String,
            detail: String?,
            permissionDisclosure: String? = nil
        ) {
            self.id = id
            self.name = name
            self.detail = detail
            self.permissionDisclosure = permissionDisclosure
        }
    }

    struct PresentedReport: Equatable {
        let kind: ReportKind
        let title: String
        let groups: [OutcomeGroup]

        var sectionTitle: String {
            switch kind {
            case .apply: "Latest Apply Report"
            case .undo: "Latest Undo Result"
            case .connection: "Latest Connection Result"
            case .disconnect: "Latest Disconnect Result"
            }
        }
    }

    struct OutcomeGroup: Equatable, Identifiable {
        let id: TargetInstanceID
        let targetName: String
        let outcomes: [PresentedOutcome]
    }

    struct PresentedOutcome: Equatable {
        let capability: String
        let configuration: String
        let reach: String?
        let detail: String?
        let userActions: [String]
        let rollback: String
        let isProblem: Bool

        var userAction: String? { userActions.first }
    }

    private struct DesiredThemePresentation {
        let variantID: String?
        let preview: ThemePreviewData?
        let title: String
        let status: String
        let explanation: String
    }

    @Published private(set) var workspace: Workspace
    @Published private(set) var applicationTargets: [ApplicationTarget]
    @Published private(set) var applyPlan: ApplyPlan?

    @Published private(set) var report: PresentedReport?
    @Published private(set) var canUndoLastThemeChange = false
    @Published private(set) var connectionReview: ConnectionPlan?
    @Published private(set) var approvalRequiredFor: TargetInstanceID?
    @Published private(set) var operationError: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isReady = true

    private let runtime: any WorkspaceRuntime

    init(runtime: any WorkspaceRuntime) {
        self.runtime = runtime
        self.workspace = runtime.workspace
        self.applicationTargets = Self.connectedApplicationTargets(in: runtime.workspace)
        self.isReady = true
    }

    var persistenceError: String? {
        runtime.persistenceError
    }

    var themePacks: [ThemePack] {
        runtime.themePacks
    }

    var workspaceName: String {
        workspace.displayName
    }

    var connectedTargetInstanceNames: [String] {
        workspace.connectedTargetInstances.map(\.displayName)
    }

    var emptyStateMessage: String? {
        guard workspace.connectedTargetInstances.isEmpty else { return nil }
        return "No Targets are connected yet. Review Setup Needed below to choose what joins My Mac."
    }

    var bundledThemeVariants: [BundledThemeVariant] {
        themePacks.flatMap { pack in
            pack.variants.map { variant in
                BundledThemeVariant(preview: ThemePreviewData(pack: pack, variant: variant))
            }
        }
    }

    var canApplyThemes: Bool {
        runtime.canApplyThemes && persistenceError == nil && isReady
            && !workspace.connectedTargetInstances.isEmpty
    }

    var selectedThemeVariantID: String? { desiredThemePresentation.variantID }

    var selectedThemePreview: ThemePreviewData? { desiredThemePresentation.preview }

    var desiredThemeTitle: String { desiredThemePresentation.title }

    var desiredThemeStatus: String { desiredThemePresentation.status }

    var desiredThemeExplanation: String { desiredThemePresentation.explanation }

    private var desiredThemePresentation: DesiredThemePresentation {
        switch workspace.themeAssignment {
        case .fixed(let variantID):
            let variant = bundledThemeVariants.first(where: { $0.variantID == variantID })
            return DesiredThemePresentation(
                variantID: variantID,
                preview: variant?.preview,
                title: variant?.name ?? variantID,
                status: "Desired",
                explanation: "This selection is saved separately from Target outcomes. "
                    + "No Target Instance changes until Apply."
            )
        case .appearancePair:
            return DesiredThemePresentation(
                variantID: nil,
                preview: nil,
                title: "Choose a fixed Theme Variant",
                status: "Selection required",
                explanation: "This version applies one fixed Theme Variant. Choose one in Themes."
            )
        case nil:
            return DesiredThemePresentation(
                variantID: nil,
                preview: nil,
                title: "No Theme Variant selected",
                status: "Not selected",
                explanation: "Choose a Theme Variant in Themes to set the desired theme for My Mac."
            )
        }
    }

    func start() async {
        isReady = false
        operationError = nil
        do {
            let snapshot = try await runtime.start()
            replaceWorkspace(snapshot.workspace, targets: snapshot.targets)
            await refreshUndoAvailability()
            isReady = true
        } catch {
            operationError = Self.describe(error)
            isReady = false
        }
    }

    func reviewConnection(_ optionID: TargetInstanceID) async throws {
        connectionReview = try await runtime.reviewConnection(optionID: optionID)
        approvalRequiredFor = optionID
        report = nil
        operationError = nil
    }

    func connect(_ optionID: TargetInstanceID) async throws {
        guard let connectionReview,
            connectionReview.targetInstanceID == optionID
        else {
            throw ThemeEngineError.engineUnavailable
        }
        let result = try await runtime.connect(
            optionID: optionID,
            reviewedPlan: connectionReview
        )
        report = present(outcomes: result.report.outcomes, kind: .connection)
        approvalRequiredFor = nil
        self.connectionReview = nil
        replaceWorkspace(result.snapshot.workspace, targets: result.snapshot.targets)
        await refreshUndoAvailability()
    }

    func selectThemeVariant(_ variantID: String?) {
        guard let variantID else { return }
        runtime.selectFixedThemeVariant(variantID)
        workspace = runtime.workspace
        applyPlan = nil
        report = nil
        operationError = nil
    }

    @discardableResult
    func prepare(themeVariantID: String) async throws -> ApplyPlan {
        selectThemeVariant(themeVariantID)
        return try await prepareSelectedTheme()
    }

    @discardableResult
    func prepareSelectedTheme() async throws -> ApplyPlan {
        let prepared = try await runtime.prepareApplyPlan()
        applyPlan = prepared
        report = nil
        operationError = nil
        return prepared
    }

    @discardableResult
    func apply(planID: UUID) async throws -> DurableApplyReport {
        let applied = try await runtime.apply(planID: planID)
        applyPlan = nil
        report = present(outcomes: applied.outcomes, kind: .apply)
        await refreshUndoAvailability()
        operationError = nil
        return applied
    }

    @discardableResult
    func applyPreparedPlan() async throws -> DurableApplyReport {
        guard let applyPlan else {
            throw ThemeEngineError.planNotFound(UUID())
        }
        return try await apply(planID: applyPlan.id)
    }

    func restoreAndDisconnect(_ targetInstanceID: TargetInstanceID) async throws {
        let result = try await runtime.restoreAndDisconnect(targetInstanceID: targetInstanceID)
        report = present(outcomes: result.report.outcomes, kind: .disconnect)
        replaceWorkspace(result.snapshot.workspace, targets: result.snapshot.targets)
        await refreshUndoAvailability()
        operationError = nil
    }

    @discardableResult
    func undoLastThemeChange() async throws -> UndoReport {
        let undone = try await runtime.undoLast()
        report = present(outcomes: undone.outcomes, kind: .undo)
        await refreshUndoAvailability()
        operationError = nil
        return undone
    }

    func refreshUndoAvailability() async {
        do {
            canUndoLastThemeChange = try await runtime.undoAvailability() != .unavailable
        } catch {
            canUndoLastThemeChange = false
            operationError = Self.describe(error)
        }
    }

    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        operationError = nil
        Task { @MainActor in
            defer { isBusy = false }
            do {
                try await operation()
            } catch {
                operationError = Self.describe(error)
            }
        }
    }

    func present(outcomes: [TargetCapabilityOutcome], kind: ReportKind) -> PresentedReport {
        let targetsByID = Dictionary(
            uniqueKeysWithValues: workspace.connectedTargetInstances.map { ($0.id, $0) }
        )
        let grouped = Dictionary(grouping: outcomes, by: \.targetInstanceID)
        let groups = grouped.keys.sorted { left, right in
            let leftAdapter = targetsByID[left]?.adapterID ?? grouped[left]?.first?.adapterID ?? ""
            let rightAdapter = targetsByID[right]?.adapterID ?? grouped[right]?.first?.adapterID ?? ""
            let leftRank = WorkspaceTargetOrder.rank(adapterID: leftAdapter)
            let rightRank = WorkspaceTargetOrder.rank(adapterID: rightAdapter)
            if leftRank != rightRank { return leftRank < rightRank }
            if leftAdapter != rightAdapter { return leftAdapter < rightAdapter }
            return left.rawValue < right.rawValue
        }.map { targetID in
            OutcomeGroup(
                id: targetID,
                targetName: targetsByID[targetID]?.displayName ?? displayName(for: grouped[targetID]?.first?.adapterID),
                outcomes: (grouped[targetID] ?? []).sorted { $0.capabilityID < $1.capabilityID }.map {
                    present(outcome: $0, kind: kind)
                }
            )
        }
        let hasUpdate = outcomes.contains { $0.configurationState == .updated }
        let hasUnchanged = outcomes.contains { $0.configurationState == .unchanged }
        let hasSuccess = hasUpdate || hasUnchanged
        let hasProblem = outcomes.contains {
            [.permissionRequired, .conflicted, .failed, .unavailable]
                .contains($0.configurationState)
        }
        let title: String
        switch (kind, hasSuccess, hasProblem) {
        case (.apply, true, false) where hasUpdate: title = "Theme applied"
        case (.apply, true, true) where hasUpdate: title = "Theme applied with remaining work"
        case (.apply, true, false): title = "Theme already applied"
        case (.apply, true, true): title = "Theme unchanged with remaining work"
        case (.apply, false, _): title = "Theme not applied"
        case (.undo, true, false): title = "Theme change undone"
        case (.undo, true, true): title = "Theme change undone with remaining work"
        case (.undo, false, _): title = "Theme change not undone"
        case (.connection, true, false): title = "Connection updated"
        case (.connection, true, true): title = "Connection updated with remaining work"
        case (.connection, false, _): title = "Connection not updated"
        case (.disconnect, true, false): title = "Target restored and disconnected"
        case (.disconnect, true, true): title = "Target disconnected with remaining work"
        case (.disconnect, false, _): title = "Target not disconnected"
        }
        return PresentedReport(kind: kind, title: title, groups: groups)
    }

    func replaceWorkspace(_ workspace: Workspace, targets: [ApplicationTarget]) {
        self.workspace = workspace
        applicationTargets = targets
        applyPlan = nil
    }

    private func present(outcome: TargetCapabilityOutcome, kind: ReportKind) -> PresentedOutcome {
        let configuration: String
        switch outcome.configurationState {
        case .updated: configuration = "Updated"
        case .unchanged: configuration = "Already set"
        case .permissionRequired: configuration = "Permission required"
        case .conflicted: configuration = "Conflict"
        case .failed: configuration = "Failed"
        case .unavailable: configuration = "Unavailable"
        }

        let reach: String?
        switch outcome.runningInstanceReach {
        case .currentInstances: reach = "Current windows"
        case .nextPrompt: reach = "Next prompt"
        case .newProcessesOnly: reach = "Next launch"
        case .reloadRequired: reach = "Reload required"
        case .unavailable: reach = nil
        }

        let userActions = outcome.userActions.map(\.detail)

        let rollback: String
        switch outcome.rollbackState {
        case .notNeeded: rollback = "No rollback needed"
        case .undoAvailable: rollback = "Undo available"
        case .restored: rollback = "Restored"
        case .blocked: rollback = "Restore blocked"
        case .recoveryRequired: rollback = "Recovery required"
        }

        return PresentedOutcome(
            capability: capabilityName(outcome.capabilityID),
            configuration: configuration,
            reach: reach,
            detail: outcome.detail,
            userActions: userActions,
            rollback: rollback,
            isProblem: [.permissionRequired, .conflicted, .failed, .unavailable]
                .contains(outcome.configurationState)
        )
    }

    private func capabilityName(_ capabilityID: String) -> String {
        switch capabilityID {
        case "colorTheme", "theme": "Theme"
        case "appearance": "Appearance"
        case "wallpaper": "Wallpaper"
        case "connection": "Connection"
        case "disconnect": "Disconnect"
        default: capabilityID
        }
    }

    private func displayName(for adapterID: String?) -> String {
        switch adapterID {
        case "macos.appearance", "macos.wallpaper": "macOS"
        case "ghostty": "Ghostty"
        case "vscode": "Visual Studio Code"
        case "starship": "Starship"
        default: "Target Instance"
        }
    }

    private static func connectedApplicationTargets(in workspace: Workspace) -> [ApplicationTarget] {
        let groups = Dictionary(grouping: workspace.connectedTargetInstances) { applicationID(for: $0.adapterID) }
        return groups.keys.sorted { targetRank($0) < targetRank($1) }.map { applicationID in
            let instances = groups[applicationID] ?? []
            return ApplicationTarget(
                id: applicationID,
                name: applicationName(applicationID),
                systemImage: systemImage(applicationID),
                state: .connected,
                summary: instances.count == 1 ? "Connected" : "\(instances.count) Target Instances connected",
                instanceDetails: instances.map(\.displayName),
                connectionOptions: []
            )
        }
    }

    private static func applicationID(for adapterID: String) -> String {
        adapterID.hasPrefix("macos.") ? "macos" : adapterID
    }

    private static func applicationName(_ id: String) -> String {
        switch id {
        case "macos": "macOS"
        case "ghostty": "Ghostty"
        case "vscode": "Visual Studio Code"
        case "starship": "Starship"
        default: id
        }
    }

    private static func systemImage(_ id: String) -> String {
        switch id {
        case "macos": "macbook"
        case "ghostty": "terminal"
        case "vscode": "chevron.left.forwardslash.chevron.right"
        case "starship": "sparkles"
        default: "app"
        }
    }

    private static func targetRank(_ id: String) -> Int {
        WorkspaceTargetOrder.rank(adapterID: id == "macos" ? "macos.appearance" : id)
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case ThemeEngineError.fixedThemeAssignmentRequired:
            "Choose a Theme Variant before preparing an Apply Plan."
        case DurableOperationError.noLastApplyTransaction:
            "There is no theme change left to undo."
        case DurableOperationError.persistenceRequired:
            "Recovery storage is unavailable, so Oh My Theme refused to change your Workspace."
        default:
            String(describing: error)
        }
    }

    struct BundledThemeVariant: Equatable, Identifiable {
        let preview: ThemePreviewData

        var id: String { preview.id }
        var name: String { preview.displayName }
        var variantID: String { preview.variantID }
        var appearance: ThemeAppearance { preview.appearance }
        var source: ThemeSource { preview.source }
    }
}
