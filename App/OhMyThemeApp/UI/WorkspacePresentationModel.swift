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
        case setup
    }

    struct ApplicationTarget: Equatable, Identifiable {
        typealias State = TargetManagementState

        let id: String
        let name: String
        let systemImage: String
        let state: TargetManagementState
        let summary: String
        let instanceDetails: [String]
        let connectionOptions: [ConnectionOption]
        let instances: [TargetInstanceItem]

        init(
            id: String,
            name: String,
            systemImage: String,
            state: TargetManagementState,
            summary: String,
            instanceDetails: [String],
            connectionOptions: [ConnectionOption],
            instances: [TargetInstanceItem] = []
        ) {
            self.id = id
            self.name = name
            self.systemImage = systemImage
            self.state = state
            self.summary = summary
            self.instanceDetails = instanceDetails
            self.connectionOptions = connectionOptions
            self.instances = instances
        }

        var showsInstanceDetails: Bool {
            state == .unavailable || connectionOptions.count > 1 || instances.count > 1
        }

        var showsConnectionOptionDetails: Bool {
            state == .unavailable || connectionOptions.count > 1
        }

        var hasRecommendedInstances: Bool {
            instances.contains(where: \.isRecommended)
        }

        var allRecommendedOptedIn: Bool {
            let rec = instances.filter(\.isRecommended)
            return !rec.isEmpty && rec.allSatisfy(\.isOptedIn)
        }

        var canSelectRecommended: Bool {
            instances.contains { $0.isRecommended && !$0.isOptedIn }
        }
    }

    struct TargetInstanceItem: Equatable, Identifiable {
        let id: TargetInstanceID
        let displayName: String
        let detail: String?
        let adapterID: String
        let managementState: TargetManagementState
        let isOptedIn: Bool
        let isConnected: Bool
        let isRecommended: Bool
        let exclusionReason: RecommendationExclusionReason?
        let exclusionDetail: String?
        let permissionDisclosure: String?

        init(
            id: TargetInstanceID,
            displayName: String,
            detail: String? = nil,
            adapterID: String,
            managementState: TargetManagementState,
            isOptedIn: Bool,
            isConnected: Bool,
            isRecommended: Bool,
            exclusionReason: RecommendationExclusionReason? = nil,
            exclusionDetail: String? = nil,
            permissionDisclosure: String? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.detail = detail
            self.adapterID = adapterID
            self.managementState = managementState
            self.isOptedIn = isOptedIn
            self.isConnected = isConnected
            self.isRecommended = isRecommended
            self.exclusionReason = exclusionReason
            self.exclusionDetail = exclusionDetail
            self.permissionDisclosure = permissionDisclosure
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
            case .setup: "Latest Setup Report"
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

    private static let acknowledgedUnavailableTargetsDefaultsKey = "OhMyThemeAcknowledgedUnavailableTargets"

    @Published private(set) var workspace: Workspace
    @Published private(set) var applicationTargets: [ApplicationTarget]
    @Published private(set) var applyPlan: ApplyPlan?
    @Published private(set) var acknowledgedUnavailableTargetInstanceIDs: Set<TargetInstanceID>
    @Published private(set) var setupPlan: SetupPlan?
    @Published private(set) var setupPlanInvalidationReason: String?
    @Published private(set) var isPreparingSetupPlan = false
    @Published private(set) var setupProgress: SetupProgress?
    @Published private(set) var isExecutingSetup = false
    @Published private(set) var isCancellingRemainingSetup = false
    @Published private(set) var isApplyingTheme = false
    @Published private(set) var applyProgress: ApplyProgress?
    @Published private(set) var isCancellingRemainingApply = false
    @Published private(set) var latestSetupReport: SetupReport?
    @Published private(set) var latestApplyReport: DurableApplyReport?
    @Published var onboardingDisposition: OnboardingDisposition
    @Published var currentOnboardingStepOverride: OnboardingStep?
    @Published var hasAcknowledgedContract = false
    @Published var hasAcknowledgedSetupResults = false

    @Published private(set) var report: PresentedReport?
    @Published private(set) var canUndoLastThemeChange = false
    @Published private(set) var connectionReview: ConnectionPlan?
    @Published private(set) var approvalRequiredFor: TargetInstanceID?
    @Published private(set) var operationError: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isReady = true
    @Published var selectedSection: NavigationSection = .overview
    weak var presenceController: AppPresenceController?

    var isWorkActive: Bool {
        isExecutingSetup || isApplyingTheme
    }

    func navigateTo(targetState: NotificationTargetState) {
        switch targetState {
        case .setupResults:
            if latestSetupReport != nil {
                hasAcknowledgedSetupResults = false
            }
            selectedSection = .apps
        case .applyResults, .recovery, .preflightReview:
            selectedSection = .overview
        }
    }

    private let runtime: any WorkspaceRuntime

    init(runtime: any WorkspaceRuntime) {
        self.runtime = runtime
        self.workspace = runtime.workspace
        self.applicationTargets = Self.connectedApplicationTargets(in: runtime.workspace)
        self.acknowledgedUnavailableTargetInstanceIDs = Set(
            (UserDefaults.standard.stringArray(forKey: Self.acknowledgedUnavailableTargetsDefaultsKey) ?? [])
                .map(TargetInstanceID.init(rawValue:))
        )
        self.latestSetupReport = runtime.latestSetupReport
        self.latestApplyReport = runtime.latestApplyReport
        self.onboardingDisposition = runtime.onboardingDisposition
        self.currentOnboardingStepOverride = nil
        self.hasAcknowledgedContract = false
        self.hasAcknowledgedSetupResults = false
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

    var isOnboardingActive: Bool {
        onboardingDisposition == .inProgress
    }

    var isOnboardingDeferred: Bool {
        onboardingDisposition == .deferred
    }

    var isOnboardingCompleted: Bool {
        onboardingDisposition == .completed
    }

    var currentOnboardingStep: OnboardingStep {
        currentOnboardingStepOverride ?? derivedOnboardingStep
    }

    var derivedOnboardingStep: OnboardingStep {
        if onboardingDisposition == .completed {
            return .overview
        }
        if onboardingDisposition == .deferred {
            return .overview
        }
        if isExecutingSetup {
            return .setupTransaction
        }
        if isApplyingTheme {
            return .initialApply
        }
        if latestSetupReport != nil && !hasAcknowledgedSetupResults {
            return .setupResults
        }
        if setupPlan != nil {
            return .setupPlanReview
        }
        if !workspace.connectedTargetInstances.isEmpty {
            if latestApplyReport != nil || (workspaceThemeStatus?.isFullyApplied == true && (workspaceThemeStatus?.appliedCount ?? 0) > 0) {
                return .overview
            }
            return .initialApply
        }
        if workspace.themeAssignment != nil {
            return .targetOptIns
        }
        if hasAcknowledgedContract {
            return .desiredTheme
        }
        return .contract
    }

    var checkedApplicationsSummary: String {
        "Oh My Theme checked for compatible installations of macOS Appearance, Wallpaper displays, Ghostty, Starship, and VS Code, but none are currently available to configure automatically."
    }

    func acknowledgeContract() {
        hasAcknowledgedContract = true
        currentOnboardingStepOverride = nil
    }

    func acknowledgeSetupResults() {
        hasAcknowledgedSetupResults = true
        setupPlan = nil
        currentOnboardingStepOverride = nil
    }

    var canFinishOnboardingFromSetupResults: Bool {
        !workspace.connectedTargetInstances.isEmpty
    }

    func deferOnboarding() {
        onboardingDisposition = .deferred
        currentOnboardingStepOverride = nil
        Task {
            do {
                try await runtime.updateOnboardingDisposition(.deferred)
            } catch {
                operationError = "Failed to defer onboarding: \(error.localizedDescription)"
            }
        }
    }

    func resumeOnboarding() {
        onboardingDisposition = .inProgress
        currentOnboardingStepOverride = nil
        hasAcknowledgedContract = true
        Task {
            do {
                try await runtime.updateOnboardingDisposition(.inProgress)
            } catch {
                operationError = "Failed to resume onboarding: \(error.localizedDescription)"
            }
        }
    }

    func completeOnboarding() {
        onboardingDisposition = .completed
        currentOnboardingStepOverride = nil
        Task {
            do {
                try await runtime.updateOnboardingDisposition(.completed)
            } catch {
                operationError = "Failed to complete onboarding: \(error.localizedDescription)"
            }
        }
    }

    #if DEBUG
    func setLatestSetupReportForTesting(_ report: SetupReport?) {
        self.latestSetupReport = report
    }
    #endif

    func goToOnboardingStep(_ step: OnboardingStep) {
        currentOnboardingStepOverride = step
    }

    func resetOnboardingStepOverride() {
        currentOnboardingStepOverride = nil
    }

    var canApplyThemes: Bool {
        runtime.canApplyThemes && persistenceError == nil && isReady
            && !workspace.connectedTargetInstances.isEmpty
    }

    var hasRecommendedTargets: Bool {
        applicationTargets.contains(where: \.hasRecommendedInstances)
    }

    var canSelectAllRecommended: Bool {
        applicationTargets.contains(where: \.canSelectRecommended)
    }

    var hasUnresolvedOptedInTargets: Bool {
        unresolvedOptedInCount > 0
    }

    var unresolvedOptedInCount: Int {
        let countFromInstances = applicationTargets.flatMap(\.instances).filter { $0.isOptedIn && !$0.isConnected }
            .count
        let countFromWorkspace = workspace.targetOptIns.filter { !workspace.isConnected($0) }.count
        return max(countFromInstances, countFromWorkspace)
    }

    var canReviewSetupPlan: Bool {
        hasUnresolvedOptedInTargets && !isBusy
    }

    var isSetupPlanInvalidated: Bool {
        setupPlanInvalidationReason != nil
    }

    var canRetryRemainingSetup: Bool {
        hasRetryableSetupTargets && !isBusy
    }

    var workspaceThemeStatus: WorkspaceThemeStatus? {
        runtime.workspaceThemeStatus
    }

    var unresolvedRecovery: String? {
        runtime.unresolvedRecovery
    }

    var appliedTargetsCount: Int {
        workspaceThemeStatus?.appliedCount ?? 0
    }

    var pendingTargetsCount: Int {
        workspaceThemeStatus?.pendingCount ?? 0
    }

    var needsAttentionTargetsCount: Int {
        workspaceThemeStatus?.needsAttentionCount ?? 0
    }

    var isFullyApplied: Bool {
        workspaceThemeStatus?.isFullyApplied ?? false
    }

    var activeOperationSummary: String? {
        if isCancellingRemainingApply {
            return "Cancelling theme application…"
        }
        if isApplyingTheme {
            return "Applying Theme…"
        }
        if isCancellingRemainingSetup {
            return "Cancelling setup…"
        }
        if isExecutingSetup {
            return "Connecting Targets…"
        }
        if isPreparingSetupPlan {
            return "Preparing Setup Plan…"
        }
        if isBusy {
            return "Working…"
        }
        return nil
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
            latestSetupReport = runtime.latestSetupReport
            latestApplyReport = runtime.latestApplyReport
            onboardingDisposition = runtime.onboardingDisposition
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

    func refreshTargets() async throws {
        let snapshot = try await runtime.refreshTargets()
        replaceWorkspace(snapshot.workspace, targets: snapshot.targets)
        await revalidateSetupPlan()
    }

    func setTargetOptIn(_ instanceID: TargetInstanceID, isOptedIn: Bool) async throws {
        let snapshot = try await runtime.setTargetOptIn(instanceID: instanceID, isOptedIn: isOptedIn)
        replaceWorkspace(snapshot.workspace, targets: snapshot.targets)
        await revalidateSetupPlan()
    }

    func selectAllRecommended() async throws {
        let snapshot = try await runtime.selectAllRecommended()
        replaceWorkspace(snapshot.workspace, targets: snapshot.targets)
        await revalidateSetupPlan()
    }

    func selectRecommended(for applicationID: String) async throws {
        let snapshot = try await runtime.selectRecommended(applicationID: applicationID)
        replaceWorkspace(snapshot.workspace, targets: snapshot.targets)
        await revalidateSetupPlan()
    }

    func prepareSetupPlan(retrySourceOperationID: UUID? = nil) async {
        guard isPreparingSetupPlan == false else { return }
        isPreparingSetupPlan = true
        defer { isPreparingSetupPlan = false }
        do {
            setupPlan = try await runtime.prepareSetupPlan(retrySourceOperationID: retrySourceOperationID)
            setupPlanInvalidationReason = nil
        } catch {
            operationError = Self.describe(error)
            setupPlan = nil
        }
    }

    func dismissSetupPlan() {
        guard !isExecutingSetup else { return }
        setupPlan = nil
        setupPlanInvalidationReason = nil
        setupProgress = nil
    }

    func revalidateSetupPlan() async {
        guard let plan = setupPlan, setupPlanInvalidationReason == nil else { return }
        let result = await runtime.validateSetupPlanPreconditions(plan)
        if case .invalidated(let reason) = result {
            setupPlanInvalidationReason = reason
        }
    }

    @discardableResult
    func confirmSetupPlan() async -> Bool {
        await revalidateSetupPlan()
        guard !isSetupPlanInvalidated else { return false }
        return true
    }

    func retryRemainingSetup() async {
        guard !isBusy,
            hasRetryableSetupTargets,
            let latestSetupReport
        else { return }
        await prepareSetupPlan(retrySourceOperationID: latestSetupReport.operationID)
    }

    func cancelRemainingApply() async {
        guard isApplyingTheme,
            !isCancellingRemainingApply,
            let operationID = applyProgress?.operationID ?? applyPlan?.id
        else { return }
        isCancellingRemainingApply = true
        defer { isCancellingRemainingApply = false }
        do {
            try await runtime.cancelRemainingApply(operationID: operationID)
        } catch {
            operationError = Self.describe(error)
        }
    }

    func cancelRemainingSetup() async {
        guard isExecutingSetup,
            !isCancellingRemainingSetup,
            let operationID = setupProgress?.operationID
        else { return }
        isCancellingRemainingSetup = true
        defer { isCancellingRemainingSetup = false }
        do {
            try await runtime.cancelRemainingSetup(operationID: operationID)
        } catch {
            operationError = Self.describe(error)
        }
    }

    @discardableResult
    func executeSetupPlan() async throws -> SetupReport? {
        guard let plan = setupPlan else { return nil }
        await revalidateSetupPlan()
        guard !isSetupPlanInvalidated else { return nil }
        guard !isBusy else { return nil }

        isExecutingSetup = true
        isBusy = true
        operationError = nil
        presenceController?.workDidStart()
        defer {
            isExecutingSetup = false
            isBusy = false
        }

        do {
            let result = try await runtime.executeSetupPlan(plan) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.setupProgress = progress
                }
            }
            replaceWorkspace(result.snapshot.workspace, targets: result.snapshot.targets)
            setupPlan = nil
            setupPlanInvalidationReason = nil
            setupProgress = nil
            latestSetupReport = result.report
            report = present(outcomes: result.report.combinedOutcomes, kind: .setup)
            await presenceController?.workDidFinish(.setup(result.report))
            return result.report
        } catch {
            await presenceController?.workDidFinish(.setupFailed(error))
            if case ProductionWorkspaceRuntimeError.setupPlanInvalidated(let reason) = error {
                setupPlanInvalidationReason = reason
            } else if case DurableOperationError.operationCancelled = error {
                operationError = "Setup was cancelled."
                return nil
            } else {
                operationError = Self.describe(error)
            }
            throw error
        }
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
    func apply(planID: UUID) async throws -> DurableApplyReport? {
        guard !isBusy, !isApplyingTheme, !isExecutingSetup else { return nil }
        isBusy = true
        isApplyingTheme = true
        operationError = nil
        presenceController?.workDidStart()
        defer {
            isBusy = false
            isApplyingTheme = false
            isCancellingRemainingApply = false
            applyProgress = nil
        }
        do {
            let applied = try await runtime.apply(planID: planID) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.applyProgress = progress
                }
            }
            applyPlan = nil
            applyProgress = nil
            latestApplyReport = applied
            report = present(outcomes: applied.outcomes, kind: .apply)
            await refreshUndoAvailability()
            operationError = nil
            await presenceController?.workDidFinish(.apply(applied))
            return applied
        } catch {
            await presenceController?.workDidFinish(.applyFailed(error))
            applyProgress = nil
            if case DurableOperationError.operationCancelled = error {
                operationError = "Theme application was cancelled."
                return nil
            }
            operationError = Self.describe(error)
            throw error
        }
    }

    @discardableResult
    func applyDesiredTheme() async throws -> DurableApplyReport? {
        guard !isBusy, !isApplyingTheme, !isExecutingSetup else { return nil }
        isBusy = true
        isApplyingTheme = true
        operationError = nil
        presenceController?.workDidStart()
        defer {
            isBusy = false
            isApplyingTheme = false
            isCancellingRemainingApply = false
            applyProgress = nil
        }
        do {
            let prepared = try await runtime.prepareApplyPlan()
            if prepared.isClean(acknowledgedUnavailableTargets: acknowledgedUnavailableTargetInstanceIDs) {
                applyPlan = nil
                let applied = try await runtime.apply(planID: prepared.id) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.applyProgress = progress
                    }
                }
                self.applyProgress = nil
                self.latestApplyReport = applied
                report = present(outcomes: applied.outcomes, kind: .apply)
                await refreshUndoAvailability()
                await presenceController?.workDidFinish(.apply(applied))
                return applied
            } else {
                applyPlan = prepared
                await presenceController?.workDidFinish(.preflightPaused(prepared))
                return nil
            }
        } catch {
            await presenceController?.workDidFinish(.applyFailed(error))
            self.applyProgress = nil
            if case DurableOperationError.operationCancelled = error {
                operationError = "Theme application was cancelled."
                return nil
            }
            operationError = Self.describe(error)
            throw error
        }
    }

    @discardableResult
    func applyPreparedPlan() async throws -> DurableApplyReport? {
        guard !isBusy, !isApplyingTheme, !isExecutingSetup else { return nil }
        guard let applyPlan else {
            throw ThemeEngineError.planNotFound(UUID())
        }
        isBusy = true
        isApplyingTheme = true
        operationError = nil
        presenceController?.workDidStart()
        defer {
            isBusy = false
            isApplyingTheme = false
            isCancellingRemainingApply = false
            applyProgress = nil
        }
        do {
            acknowledgedUnavailableTargetInstanceIDs.formUnion(applyPlan.unavailableTargetInstanceIDs)
            UserDefaults.standard.set(
                acknowledgedUnavailableTargetInstanceIDs.map(\.rawValue),
                forKey: Self.acknowledgedUnavailableTargetsDefaultsKey
            )
            let applied = try await runtime.apply(
                planID: applyPlan.id,
                targetInstanceIDs: Set(applyPlan.readyTargetInstanceIDs)
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.applyProgress = progress
                }
            }
            self.applyPlan = nil
            self.applyProgress = nil
            self.latestApplyReport = applied
            report = present(outcomes: applied.outcomes, kind: .apply)
            await refreshUndoAvailability()
            await presenceController?.workDidFinish(.apply(applied))
            return applied
        } catch {
            await presenceController?.workDidFinish(.applyFailed(error))
            self.applyProgress = nil
            if case DurableOperationError.operationCancelled = error {
                operationError = "Theme application was cancelled."
                return nil
            }
            operationError = Self.describe(error)
            throw error
        }
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
                targetName: targetsByID[targetID]?.displayName
                    ?? applicationTargets.flatMap(\.instances).first(where: { $0.id == targetID })?.displayName
                    ?? displayName(for: grouped[targetID]?.first?.adapterID),
                outcomes: (grouped[targetID] ?? []).sorted { $0.capabilityID < $1.capabilityID }.map {
                    present(outcome: $0, kind: kind)
                }
            )
        }
        let hasUpdate = outcomes.contains { $0.configurationState == .updated }
        let hasUnchanged = outcomes.contains { $0.configurationState == .unchanged }
        let hasSuccess = hasUpdate || hasUnchanged
        let hasProblem = outcomes.contains(where: isProblem)
        let title: String
        switch (kind, hasSuccess, hasProblem) {
        case (.apply, true, false) where hasUpdate: title = "Theme applied"
        case (.apply, true, true) where hasUpdate: title = "Theme applied with remaining work"
        case (.apply, true, false): title = "My Mac is up to date"
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
        case (.setup, true, false) where hasUpdate: title = "Setup complete"
        case (.setup, true, true) where hasUpdate: title = "Setup complete with remaining work"
        case (.setup, true, false): title = "Apps already configured"
        case (.setup, true, true): title = "Setup unchanged with remaining work"
        case (.setup, false, _): title = "Setup not completed"
        }
        return PresentedReport(kind: kind, title: title, groups: groups)
    }

    func replaceWorkspace(_ workspace: Workspace, targets: [ApplicationTarget]) {
        self.workspace = workspace
        applicationTargets = targets
        applyPlan = nil
    }

    private var hasRetryableSetupTargets: Bool {
        guard let latestSetupReport else { return false }
        return latestSetupReport.combinedOutcomes.contains { outcome in
            workspace.targetOptIns.contains(outcome.targetInstanceID)
                && !workspace.isConnected(outcome.targetInstanceID)
                && [.failed, .needsPermission, .conflict, .unavailable, .skipped]
                    .contains(latestSetupReport.outcomeKind(for: outcome))
        }
    }

    private func present(outcome: TargetCapabilityOutcome, kind: ReportKind) -> PresentedOutcome {
        let configuration: String
        if outcome.rollbackState == .recoveryRequired {
            configuration = "Recovery required"
        } else {
            switch outcome.configurationState {
            case .updated: configuration = kind == .setup ? "Connected" : "Updated"
            case .unchanged:
                if outcome.detail == "Skipped after Cancel Remaining." {
                    configuration = "Skipped"
                } else {
                    configuration = "Already set"
                }
            case .permissionRequired: configuration = "Permission required"
            case .conflicted: configuration = "Conflict"
            case .failed: configuration = "Failed"
            case .unavailable: configuration = "Unavailable"
            }
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
            isProblem: isProblem(outcome)
        )
    }

    private func isProblem(_ outcome: TargetCapabilityOutcome) -> Bool {
        outcome.rollbackState == .recoveryRequired
            || [.permissionRequired, .conflicted, .failed, .unavailable]
                .contains(outcome.configurationState)
            || (outcome.configurationState == .unchanged && outcome.detail == "Skipped after Cancel Remaining.")
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
            let targetItems = instances.map { instance in
                TargetInstanceItem(
                    id: instance.id,
                    displayName: instance.displayName,
                    adapterID: instance.adapterID,
                    managementState: .connected,
                    isOptedIn: true,
                    isConnected: true,
                    isRecommended: RecommendedTargetPolicy.isAllowlisted(adapterID: instance.adapterID)
                )
            }
            return ApplicationTarget(
                id: applicationID,
                name: applicationName(applicationID),
                systemImage: systemImage(applicationID),
                state: .connected,
                summary: instances.count == 1 ? "Connected" : "\(instances.count) Target Instances connected",
                instanceDetails: instances.map(\.displayName),
                connectionOptions: [],
                instances: targetItems
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
        case ThemeEngineError.planMembershipChanged:
            "Selected targets changed since the plan was prepared."
        case ThemeEngineError.corruptPlanState(_, let reason):
            "Setup plan is corrupt: \(reason)"
        default:
            String(describing: error)
        }
    }

    #if DEBUG
    func setBusyForTesting(_ busy: Bool) {
        self.isBusy = busy
    }

    func setIsExecutingSetupForTesting(_ executing: Bool) {
        self.isExecutingSetup = executing
    }

    func setIsCancellingRemainingSetupForTesting(_ cancelling: Bool) {
        self.isCancellingRemainingSetup = cancelling
    }

    func setIsApplyingThemeForTesting(_ applying: Bool) {
        self.isApplyingTheme = applying
    }

    func setIsCancellingRemainingApplyForTesting(_ cancelling: Bool) {
        self.isCancellingRemainingApply = cancelling
    }

    func setApplyProgressForTesting(_ progress: ApplyProgress?) {
        self.applyProgress = progress
    }
    #endif

    struct BundledThemeVariant: Equatable, Identifiable {
        let preview: ThemePreviewData

        var id: String { preview.id }
        var name: String { preview.displayName }
        var variantID: String { preview.variantID }
        var appearance: ThemeAppearance { preview.appearance }
        var source: ThemeSource { preview.source }
    }
}
