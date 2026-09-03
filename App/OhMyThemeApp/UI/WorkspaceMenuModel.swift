import AppKit
import Combine
import PlatformClients
import ThemeEngine
import ThemeModel

@MainActor
final class WorkspaceMenuModel: ObservableObject {
    enum ReportKind: Equatable {
        case apply
        case undo
        case connection
        case disconnect
    }

    struct ApplicationTarget: Equatable, Identifiable {
        enum State: String, Equatable {
            case ready = "Ready"
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

    @Published private(set) var workspace: Workspace
    @Published private(set) var applicationTargets: [ApplicationTarget]
    @Published private(set) var preview: ThemePreview?
    @Published private(set) var report: PresentedReport?
    @Published private(set) var canUndoLastThemeChange = false
    @Published private(set) var connectionReview: ConnectionPlan?
    @Published private(set) var approvalRequiredFor: TargetInstanceID?
    @Published private(set) var operationError: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isReady = true
    @Published private(set) var launchAtLoginStatus: LaunchAtLoginStatus
    @Published private(set) var isChangingLaunchAtLogin = false
    @Published private(set) var launchAtLoginError: String?

    private let launchAtLogin: any LaunchAtLoginPlatform
    private let quitAction: @MainActor () -> Void
    private let themePacks: [ThemePack]
    private let themeEngine: ThemeEngine?
    private let themeVariantSelection: (String) -> Void
    private let runtime: (any WorkspaceRuntime)?
    let persistenceError: String?

    init(
        workspace: Workspace,
        themePacks: [ThemePack]? = nil,
        themeEngine: ThemeEngine? = nil,
        applicationTargets: [ApplicationTarget]? = nil,
        runtime: (any WorkspaceRuntime)? = nil,
        themeVariantSelection: @escaping (String) -> Void = { _ in },
        persistenceError: String? = nil,
        launchAtLogin: any LaunchAtLoginPlatform = LaunchAtLoginClient(),
        quitAction: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.workspace = workspace
        self.themePacks = themePacks ?? ((try? BundledThemeCatalog().load()) ?? [])
        self.themeEngine = themeEngine
        self.runtime = runtime
        self.themeVariantSelection = themeVariantSelection
        self.persistenceError = persistenceError
        self.launchAtLogin = launchAtLogin
        self.launchAtLoginStatus = launchAtLogin.status
        self.quitAction = quitAction
        self.applicationTargets = applicationTargets ?? Self.connectedApplicationTargets(in: workspace)
        self.isReady = runtime == nil
    }

    convenience init(
        runtime: any WorkspaceRuntime,
        launchAtLogin: any LaunchAtLoginPlatform = LaunchAtLoginClient()
    ) {
        self.init(
            workspace: runtime.workspace,
            themePacks: runtime.themePacks,
            themeEngine: runtime.themeEngine,
            runtime: runtime,
            themeVariantSelection: { variantID in runtime.selectFixedThemeVariant(variantID) },
            persistenceError: runtime.persistenceError,
            launchAtLogin: launchAtLogin
        )
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
            pack.variants.map {
                BundledThemeVariant(
                    name: "\(pack.displayName) \($0.displayName)",
                    variantID: $0.qualifiedID,
                    appearance: $0.appearance.rawValue,
                    sourceType: pack.source.type.rawValue,
                    sourceRevision: pack.source.revision,
                    attribution: pack.source.attribution
                )
            }
        }
    }

    var isLaunchAtLoginSelected: Bool {
        launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
    }

    var canChangeLaunchAtLogin: Bool {
        launchAtLoginStatus != .unavailable && !isChangingLaunchAtLogin
    }

    var launchAtLoginDetail: String {
        switch launchAtLoginStatus {
        case .disabled:
            "Open Oh My Theme automatically after you log in."
        case .enabled:
            "Oh My Theme will open automatically after you log in."
        case .requiresApproval:
            "Allow Oh My Theme in System Settings > General > Login Items & Extensions."
        case .unavailable:
            "Launch at Login is unavailable for this copy of the app."
        }
    }

    var canApplyThemes: Bool {
        themeEngine != nil && persistenceError == nil && isReady
            && !workspace.connectedTargetInstances.isEmpty
    }

    var selectedThemeVariantID: String? {
        guard case .fixed(let variantID) = workspace.themeAssignment else { return nil }
        return variantID
    }

    func quit() {
        quitAction()
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) async {
        guard !isChangingLaunchAtLogin else { return }
        isChangingLaunchAtLogin = true
        launchAtLoginError = nil
        defer { isChangingLaunchAtLogin = false }

        do {
            try await launchAtLogin.setEnabled(enabled)
        } catch {
            launchAtLoginError =
                "macOS couldn't update Launch at Login. \(error.localizedDescription) Try the toggle again."
        }
        launchAtLoginStatus = launchAtLogin.status
    }

    func start() async {
        launchAtLoginStatus = launchAtLogin.status
        guard let runtime else {
            await refreshUndoAvailability()
            return
        }
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
        guard let runtime else { throw ThemeEngineError.engineUnavailable }
        connectionReview = try await runtime.reviewConnection(optionID: optionID)
        approvalRequiredFor = optionID
        report = nil
        operationError = nil
    }

    func connect(_ optionID: TargetInstanceID) async throws {
        guard let runtime, let connectionReview,
            connectionReview.targetInstanceID == optionID
        else { throw ThemeEngineError.engineUnavailable }
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
        workspace = Workspace(
            id: workspace.id,
            displayName: workspace.displayName,
            connectedTargetInstances: workspace.connectedTargetInstances,
            themeAssignment: .fixed(variantID: variantID)
        )
        preview = nil
        report = nil
        operationError = nil
        themeVariantSelection(variantID)
    }

    @discardableResult
    func prepare(themeVariantID: String) async throws -> ThemePreview {
        guard let themeEngine else {
            throw ThemeEngineError.engineUnavailable
        }
        selectThemeVariant(themeVariantID)
        let prepared = try await themeEngine.prepare(workspace: workspace)
        preview = prepared
        report = nil
        operationError = nil
        return prepared
    }

    @discardableResult
    func prepareSelectedTheme() async throws -> ThemePreview {
        guard let themeEngine else {
            throw ThemeEngineError.engineUnavailable
        }
        let prepared = try await themeEngine.prepare(workspace: workspace)
        preview = prepared
        report = nil
        operationError = nil
        return prepared
    }

    @discardableResult
    func apply(previewID: UUID) async throws -> DurableApplyReport {
        guard let themeEngine else {
            throw ThemeEngineError.engineUnavailable
        }
        let applied = try await themeEngine.applyDurable(previewID: previewID, workspace: workspace)
        preview = nil
        report = present(outcomes: applied.outcomes, kind: .apply)
        await refreshUndoAvailability()
        operationError = nil
        return applied
    }

    @discardableResult
    func applyPreparedPreview() async throws -> DurableApplyReport {
        guard let preview else {
            throw ThemeEngineError.previewNotFound(UUID())
        }
        return try await apply(previewID: preview.id)
    }

    func restoreAndDisconnect(_ targetInstanceID: TargetInstanceID) async throws {
        guard let runtime else { throw ThemeEngineError.engineUnavailable }
        let result = try await runtime.restoreAndDisconnect(targetInstanceID: targetInstanceID)
        report = present(outcomes: result.report.outcomes, kind: .disconnect)
        replaceWorkspace(result.snapshot.workspace, targets: result.snapshot.targets)
        await refreshUndoAvailability()
        operationError = nil
    }

    @discardableResult
    func undoLastThemeChange() async throws -> UndoReport {
        guard let themeEngine else {
            throw ThemeEngineError.engineUnavailable
        }
        let undone = try await themeEngine.undoLast(workspace: workspace)
        report = present(outcomes: undone.outcomes, kind: .undo)
        await refreshUndoAvailability()
        operationError = nil
        return undone
    }

    func refreshUndoAvailability() async {
        guard let themeEngine else {
            canUndoLastThemeChange = false
            return
        }
        do {
            canUndoLastThemeChange = try await themeEngine.undoAvailability(workspace: workspace) != .unavailable
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
        preview = nil
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
                state: .ready,
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
            "Choose a Theme Variant before preparing a preview."
        case DurableOperationError.noLastApplyTransaction:
            "There is no theme change left to undo."
        case DurableOperationError.persistenceRequired:
            "Recovery storage is unavailable, so Oh My Theme refused to change your Workspace."
        default:
            String(describing: error)
        }
    }

    struct BundledThemeVariant: Equatable {
        let name: String
        let variantID: String
        let appearance: String
        let sourceType: String
        let sourceRevision: String
        let attribution: String
    }
}

@MainActor
protocol WorkspaceRuntime: AnyObject {
    var workspace: Workspace { get }
    var themePacks: [ThemePack] { get }
    var themeEngine: ThemeEngine? { get }
    var persistenceError: String? { get }

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
}

struct WorkspaceTargetSnapshot: Equatable {
    let workspace: Workspace
    let targets: [WorkspaceMenuModel.ApplicationTarget]
}

struct WorkspaceConnectionResult: Equatable {
    let snapshot: WorkspaceTargetSnapshot
    let report: ConnectionReport
}
