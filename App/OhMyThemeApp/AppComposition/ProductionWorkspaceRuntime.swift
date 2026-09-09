import Adapters
import AppKit
import Combine
import Foundation
import PlatformClients
import ThemeEngine
import ThemeModel

struct WorkspaceTargetDiscovery {
    let ghostty: Result<GhosttyDiscoveryReport, Error>
    let wallpaper: Result<MacOSWallpaperDiscoveryReport, Error>
    let starship: Result<StarshipDiscoveryReport, Error>
    let vscode: Result<VSCodeDiscoveryReport, Error>
}

struct VSCodeCompanionRuntime {
    let server: CompanionSocketServer
    let platform: any VSCodeConnectionPlatform
    let artifact: VSCodeCompanionArtifact
}

typealias WorkspaceTargetDiscoveryProvider = @MainActor () async -> WorkspaceTargetDiscovery
typealias VSCodeCompanionBootstrap = @MainActor () throws -> VSCodeCompanionRuntime?
typealias CurrentThemeAppearanceProvider = @MainActor () -> ThemeAppearance

@MainActor
final class ProductionWorkspaceRuntime: WorkspaceRuntime {
    private enum Constants {
        static let companionExtensionID = "ohmytheme.oh-my-theme-companion"
        static let companionVersion = "0.1.0"
        static let companionSHA256 = "93633ba57e6a7002f93a7f528178b4be9ec9ab089dd7bbd9fef8bfe60506f496"
        static let vscodeProfileName = "Default"
    }

    private struct Candidate {
        let instance: ConnectedTargetInstance
        let vscodeInstallation: VSCodeInstallation?
    }

    private let store: WorkspaceStore
    private let additionalAdapters: [any ThemeAdapter]
    private let experimentalAdapterIDs: Set<String>
    private let appearanceAdapter: MacOSAppearanceAdapter
    private let wallpaperAdapter: MacOSWallpaperAdapter
    private let ghosttyAdapter: GhosttyConfigurationAdapter
    private let starshipAdapter: StarshipConfigurationAdapter
    private let vscodeDiscovery: VSCodeApplicationDiscovery
    private let targetDiscoveryProvider: WorkspaceTargetDiscoveryProvider?
    private let currentThemeAppearanceProvider: CurrentThemeAppearanceProvider
    private let vscodePlatform: (any VSCodeConnectionPlatform)?
    private let vscodeArtifact: VSCodeCompanionArtifact?
    private let socketServer: CompanionSocketServer?
    private var candidates: [TargetInstanceID: Candidate] = [:]
    private var lastDiscovery: WorkspaceTargetDiscovery?
    private var fatalStartupFailure: String?
    private var vscodeStartupFailure: String?

    let themePacks: [ThemePack]
    let themeEngine: ThemeEngine?

    var workspace: Workspace { store.workspace }

    @Published private(set) var onboardingDisposition: OnboardingDisposition
    @Published private(set) var workspaceThemeStatus: WorkspaceThemeStatus?
    @Published private(set) var unresolvedRecovery: String?
    private(set) var latestSetupReport: SetupReport?
    private(set) var latestApplyReport: DurableApplyReport?

    var workspaceStatusPublisher: AnyPublisher<Void, Never> {
        objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

    var persistenceError: String? {
        [store.persistenceError, fatalStartupFailure]
            .compactMap { $0 }
            .joined(separator: " ")
            .nilIfEmpty
    }

    var canApplyThemes: Bool {
        themeEngine != nil && persistenceError == nil
    }

    init(
        store: WorkspaceStore = WorkspaceStore(),
        themePacks: [ThemePack]? = nil,
        additionalAdapters: [any ThemeAdapter] = [],
        experimentalAdapterIDs: Set<String> = [],
        targetDiscoveryProvider: WorkspaceTargetDiscoveryProvider? = nil,
        currentThemeAppearanceProvider: @escaping CurrentThemeAppearanceProvider = {
            let match = NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua ? .dark : .light
        },
        vscodeCompanionBootstrap: VSCodeCompanionBootstrap = ProductionWorkspaceRuntime.startVSCodeCompanion
    ) {
        self.store = store
        self.additionalAdapters = additionalAdapters
        self.experimentalAdapterIDs = experimentalAdapterIDs
        self.targetDiscoveryProvider = targetDiscoveryProvider
        self.currentThemeAppearanceProvider = currentThemeAppearanceProvider
        appearanceAdapter = MacOSAppearanceAdapter()
        wallpaperAdapter = MacOSWallpaperAdapter(
            assetResolver: BundledWallpaperAssetResolver(
                baseURL: Bundle.main.resourceURL ?? Bundle.main.bundleURL
            )
        )

        let xdgConfigHome = Self.xdgConfigHome()
        ghosttyAdapter = GhosttyConfigurationAdapter(xdgConfigHome: xdgConfigHome)
        starshipAdapter = StarshipConfigurationAdapter(xdgConfigHome: xdgConfigHome)
        vscodeDiscovery = VSCodeApplicationDiscovery()

        if let themePacks {
            self.themePacks = themePacks
        } else {
            do {
                self.themePacks = try BundledThemeCatalog().load()
            } catch {
                self.themePacks = []
                fatalStartupFailure = "Bundled Theme Catalog validation failed: \(error)"
            }
        }

        let companionRuntime: VSCodeCompanionRuntime?
        do {
            companionRuntime = try vscodeCompanionBootstrap()
        } catch {
            companionRuntime = nil
            vscodeStartupFailure = "VS Code companion unavailable: \(error)"
        }
        socketServer = companionRuntime?.server
        vscodePlatform = companionRuntime?.platform
        vscodeArtifact = companionRuntime?.artifact
        onboardingDisposition = store.loadOnboardingDisposition()

        guard !self.themePacks.isEmpty else {
            themeEngine = nil
            return
        }
        let baseAdapters: [any ThemeAdapter] = [
            appearanceAdapter,
            wallpaperAdapter,
            ghosttyAdapter,
            starshipAdapter,
        ]
        themeEngine = ThemeEngine(
            packs: self.themePacks,
            adapters: baseAdapters + additionalAdapters,
            sourcePolicy: .preferUpstream,
            persistence: store.persistenceStore
        )

        let cachedOutcomes = store.loadTargetVerificationOutcomes()
        if !cachedOutcomes.isEmpty || store.workspace.themeAssignment != nil {
            workspaceThemeStatus = WorkspaceThemeStatus(
                timestamp: cachedOutcomes.map(\.verifiedAt).max() ?? Date(),
                desiredThemeAssignment: store.workspace.themeAssignment,
                targetOutcomes: cachedOutcomes
            )
        }
        latestSetupReport = try? store.persistenceStore.flatMap {
            try $0.loadLatestOperationReport(kind: .setup, workspaceID: store.workspace.id)
        }.map { try JSONDecoder().decode(SetupReport.self, from: $0) }
        latestApplyReport = try? store.persistenceStore.flatMap {
            try $0.loadLatestOperationReport(kind: .apply, workspaceID: store.workspace.id)
        }.map { try JSONDecoder().decode(DurableApplyReport.self, from: $0) }
    }

    deinit {
        socketServer?.stop()
    }

    func updateOnboardingDisposition(_ disposition: OnboardingDisposition) async throws {
        onboardingDisposition = disposition
        store.saveOnboardingDisposition(disposition)
    }

    func selectFixedThemeVariant(_ variantID: String) {
        store.selectFixedVariant(variantID)
        Task { [weak self] in
            _ = try? await self?.verifyThemeStatus()
        }
    }

    @discardableResult
    func verifyThemeStatus() async throws -> WorkspaceThemeStatus {
        guard let themeEngine else {
            let status = WorkspaceThemeStatus(
                desiredThemeAssignment: workspace.themeAssignment,
                targetOutcomes: []
            )
            self.workspaceThemeStatus = status
            return status
        }
        let status = try await themeEngine.verifyStatus(workspace: workspace)
        self.workspaceThemeStatus = status
        return status
    }

    func start() async throws -> WorkspaceTargetSnapshot {
        let themeEngine = try requiredThemeEngine()
        let discovery = await discoverAndRememberTargets()
        await registerAdapterForPersistedVSCodeTarget(from: discovery.vscode)
        do {
            try await themeEngine.reconcileInterruptedOperations()
        } catch {
            unresolvedRecovery = "Interrupted operation recovery requires attention: \(error.localizedDescription)"
        }
        _ = try? await verifyThemeStatus()
        return makeSnapshot(discovery: discovery)
    }

    func refreshTargets() async throws -> WorkspaceTargetSnapshot {
        _ = try requiredThemeEngine()
        let discovery = await discoverAndRememberTargets()
        await registerAdapterForPersistedVSCodeTarget(from: discovery.vscode)
        _ = try? await verifyThemeStatus()
        return makeSnapshot(discovery: discovery)
    }

    func reviewConnection(optionID: TargetInstanceID) async throws -> ConnectionPlan {
        let themeEngine = try requiredThemeEngine()
        guard workspace.isOptedIn(optionID) else {
            throw ProductionWorkspaceRuntimeError.targetNotOptedIn(optionID)
        }
        _ = await discoverAndRememberTargets()
        guard let candidate = candidates[optionID] else {
            throw ProductionWorkspaceRuntimeError.targetNoLongerAvailable(optionID)
        }
        if let installation = candidate.vscodeInstallation {
            await themeEngine.register(adapter: try makeVSCodeAdapter(for: installation))
        }
        return try await themeEngine.prepareConnection(instance: candidate.instance)
    }

    func connect(
        optionID: TargetInstanceID,
        reviewedPlan: ConnectionPlan
    ) async throws -> WorkspaceConnectionResult {
        let themeEngine = try requiredThemeEngine()
        guard workspace.isOptedIn(optionID) else {
            throw ProductionWorkspaceRuntimeError.targetNotOptedIn(optionID)
        }
        var discovery = await discoverAndRememberTargets()
        guard let candidate = candidates[optionID] else {
            throw ProductionWorkspaceRuntimeError.targetNoLongerAvailable(optionID)
        }
        if let installation = candidate.vscodeInstallation {
            let adapter = try makeVSCodeAdapter(for: installation)
            await themeEngine.register(adapter: adapter)
        }

        let report = try await themeEngine.connect(
            instance: candidate.instance,
            workspace: workspace,
            approveLinkedSource: true,
            reviewedPlan: reviewedPlan
        )
        discovery = await discoverAndRememberTargets()
        _ = try? await verifyThemeStatus()
        return WorkspaceConnectionResult(
            snapshot: makeSnapshot(discovery: discovery),
            report: report
        )
    }

    func restoreAndDisconnect(
        targetInstanceID: TargetInstanceID
    ) async throws -> WorkspaceConnectionResult {
        let themeEngine = try requiredThemeEngine()
        guard let instance = workspace.connectedTargetInstances.first(where: { $0.id == targetInstanceID }) else {
            throw ProductionWorkspaceRuntimeError.targetNoLongerAvailable(targetInstanceID)
        }
        let report = try await themeEngine.disconnect(instance: instance, workspace: workspace)
        let discovery = await discoverAndRememberTargets()
        _ = try? await verifyThemeStatus()
        return WorkspaceConnectionResult(
            snapshot: makeSnapshot(discovery: discovery),
            report: report
        )
    }

    func setTargetOptIn(
        instanceID: TargetInstanceID,
        isOptedIn: Bool
    ) async throws -> WorkspaceTargetSnapshot {
        if !isOptedIn && workspace.isConnected(instanceID) {
            throw ProductionWorkspaceRuntimeError.cannotOptOutConnectedTarget(instanceID)
        }
        let discovery = await currentOrDiscoveredTargets()
        let presentedItem = makeSnapshot(discovery: discovery).targets
            .flatMap(\.instances)
            .first { $0.id == instanceID }
        let persistedInstance = store.targetInstances.first { $0.id == instanceID }.map {
            ConnectedTargetInstance(
                id: $0.id,
                displayName: $0.displayName,
                adapterID: $0.adapterID
            )
        }
        let discoveredInstance = presentedItem.map {
            ConnectedTargetInstance(
                id: $0.id,
                displayName: $0.displayName,
                adapterID: $0.adapterID
            )
        }
        guard let instance = candidates[instanceID]?.instance ?? persistedInstance ?? discoveredInstance else {
            throw ProductionWorkspaceRuntimeError.targetNoLongerAvailable(instanceID)
        }
        store.setTargetOptIn(instance: instance, isOptedIn: isOptedIn)
        _ = try? await verifyThemeStatus()
        return makeSnapshot(discovery: discovery)
    }

    func selectAllRecommended() async throws -> WorkspaceTargetSnapshot {
        let discovery = await discoverAndRememberTargets()
        let snapshot = makeSnapshot(discovery: discovery)
        let recommendedIDs = snapshot.targets.flatMap { target in
            target.instances.filter(\.isRecommended).map(\.id)
        }
        let updatedOptIns = workspace.targetOptIns.union(recommendedIDs)
        let recommendedInstances = recommendedIDs.compactMap { candidates[$0]?.instance }
        store.setTargetOptIns(updatedOptIns, discoveredInstances: recommendedInstances)
        _ = try? await verifyThemeStatus()
        return makeSnapshot(discovery: discovery)
    }

    func selectRecommended(
        applicationID: String
    ) async throws -> WorkspaceTargetSnapshot {
        let discovery = await discoverAndRememberTargets()
        let snapshot = makeSnapshot(discovery: discovery)
        guard let target = snapshot.targets.first(where: { $0.id == applicationID }) else {
            return snapshot
        }
        let recommendedIDs = target.instances.filter(\.isRecommended).map(\.id)
        let updatedOptIns = workspace.targetOptIns.union(recommendedIDs)
        let recommendedInstances = recommendedIDs.compactMap { candidates[$0]?.instance }
        store.setTargetOptIns(updatedOptIns, discoveredInstances: recommendedInstances)
        _ = try? await verifyThemeStatus()
        return makeSnapshot(discovery: discovery)
    }

    private func currentOrDiscoveredTargets() async -> WorkspaceTargetDiscovery {
        if let lastDiscovery {
            return lastDiscovery
        }
        return await discoverAndRememberTargets()
    }

    private func discoverAndRememberTargets() async -> WorkspaceTargetDiscovery {
        let discovery = await discoverTargets()
        lastDiscovery = discovery
        return discovery
    }

    func prepareSetupPlan(retrySourceOperationID: UUID? = nil) async throws -> SetupPlan {
        let themeEngine = try requiredThemeEngine()
        let discovery = await discoverAndRememberTargets()
        let snapshot = makeSnapshot(discovery: discovery)
        let snapshotItems = Dictionary(
            uniqueKeysWithValues: snapshot.targets.flatMap(\.instances).map { ($0.id, $0) }
        )

        let unresolvedOptedInIDs = workspace.targetOptIns.filter { !workspace.isConnected($0) }
        var instancesToPrepare: [ConnectedTargetInstance] = []

        for optionID in unresolvedOptedInIDs {
            if let candidate = candidates[optionID] {
                if let installation = candidate.vscodeInstallation {
                    await themeEngine.register(adapter: try makeVSCodeAdapter(for: installation))
                }
                instancesToPrepare.append(candidate.instance)
            } else if let item = snapshotItems[optionID] {
                instancesToPrepare.append(
                    ConnectedTargetInstance(
                        id: item.id,
                        displayName: item.displayName,
                        adapterID: item.adapterID
                    )
                )
            } else {
                instancesToPrepare.append(
                    ConnectedTargetInstance(
                        id: optionID,
                        displayName: optionID.rawValue,
                        adapterID: "unknown"
                    )
                )
            }
        }

        return try await themeEngine.prepareSetup(
            workspace: workspace,
            instances: instancesToPrepare,
            retrySourceOperationID: retrySourceOperationID
        )
    }

    func validateSetupPlanPreconditions(_ plan: SetupPlan) async -> SetupPlanPreconditionValidation {
        guard let themeEngine else {
            return .invalidated(reason: "Theme Engine is unavailable.")
        }
        let discovery = await discoverAndRememberTargets()
        let snapshot = makeSnapshot(discovery: discovery)
        let snapshotItems = Dictionary(
            uniqueKeysWithValues: snapshot.targets.flatMap(\.instances).map { ($0.id, $0) }
        )

        let currentInstances = plan.targetInstanceIDs.compactMap { id -> ConnectedTargetInstance? in
            if let candidate = candidates[id] {
                return candidate.instance
            }
            guard let item = snapshotItems[id] else { return nil }
            return ConnectedTargetInstance(
                id: item.id,
                displayName: item.displayName,
                adapterID: item.adapterID
            )
        }

        return await themeEngine.validateSetupPlanPreconditions(
            plan: plan,
            workspace: workspace,
            currentInstances: currentInstances,
            availableTargetInstanceIDs: Set(candidates.keys)
        )
    }

    func cancelRemainingSetup(operationID: UUID) async throws {
        try await requiredThemeEngine().cancelRemainingSetup(operationID: operationID)
    }

    func cancelRemainingApply(operationID: UUID) async throws {
        try await requiredThemeEngine().cancelRemainingApply(operationID: operationID)
    }

    func executeSetupPlan(
        _ plan: SetupPlan,
        onProgress: (@Sendable (SetupProgress) -> Void)?
    ) async throws -> WorkspaceSetupResult {
        let validation = await validateSetupPlanPreconditions(plan)
        if case .invalidated(let reason) = validation {
            throw ProductionWorkspaceRuntimeError.setupPlanInvalidated(reason)
        }
        let themeEngine = try requiredThemeEngine()
        let discovery = await currentOrDiscoveredTargets()
        let snapshot = makeSnapshot(discovery: discovery)
        let snapshotItems = Dictionary(
            uniqueKeysWithValues: snapshot.targets.flatMap(\.instances).map { ($0.id, $0) }
        )

        var instancesToExecute: [ConnectedTargetInstance] = []
        for optionID in plan.targetInstanceIDs {
            if let candidate = candidates[optionID] {
                if let installation = candidate.vscodeInstallation {
                    await themeEngine.register(adapter: try makeVSCodeAdapter(for: installation))
                }
                instancesToExecute.append(candidate.instance)
            } else if let item = snapshotItems[optionID] {
                instancesToExecute.append(
                    ConnectedTargetInstance(
                        id: item.id,
                        displayName: item.displayName,
                        adapterID: item.adapterID
                    )
                )
            } else {
                instancesToExecute.append(
                    ConnectedTargetInstance(
                        id: optionID,
                        displayName: optionID.rawValue,
                        adapterID: "unknown"
                    )
                )
            }
        }

        let report = try await themeEngine.executeSetup(
            plan: plan,
            workspace: workspace,
            instances: instancesToExecute,
            onProgress: onProgress
        )
        let refreshedDiscovery = await discoverAndRememberTargets()
        _ = try? await verifyThemeStatus()
        latestSetupReport = report
        try? store.persistenceStore?.saveLatestOperationReport(
            JSONEncoder().encode(report), kind: .setup, workspaceID: workspace.id
        )
        return WorkspaceSetupResult(
            snapshot: makeSnapshot(discovery: refreshedDiscovery),
            report: report
        )
    }

    func prepareApplyPlan() async throws -> ApplyPlan {
        _ = try? await verifyThemeStatus()
        return try await requiredThemeEngine().prepare(workspace: workspace)
    }

    func apply(
        planID: UUID,
        targetInstanceIDs: Set<TargetInstanceID>? = nil,
        onProgress: (@Sendable (ApplyProgress) -> Void)? = nil
    ) async throws -> DurableApplyReport {
        _ = try? await verifyThemeStatus()
        let report = try await requiredThemeEngine().applyDurable(
            planID: planID,
            workspace: workspace,
            targetInstanceIDs: targetInstanceIDs,
            onProgress: onProgress
        )
        _ = try? await verifyThemeStatus()
        latestApplyReport = report
        try? store.persistenceStore?.saveLatestOperationReport(
            JSONEncoder().encode(report), kind: .apply, workspaceID: workspace.id
        )
        return report
    }

    func undoLast() async throws -> UndoReport {
        let report = try await requiredThemeEngine().undoLast(workspace: workspace)
        _ = try? await verifyThemeStatus()
        return report
    }

    func undoAvailability() async throws -> UndoAvailability {
        guard let themeEngine else {
            return .unavailable
        }
        return try await themeEngine.undoAvailability(workspace: workspace)
    }

    private func requiredThemeEngine() throws -> ThemeEngine {
        guard let themeEngine else {
            throw ProductionWorkspaceRuntimeError.engineUnavailable(
                fatalStartupFailure ?? "ThemeEngine is unavailable."
            )
        }
        return themeEngine
    }

    private func discoverTargets() async -> WorkspaceTargetDiscovery {
        if let targetDiscoveryProvider {
            let discovery = await targetDiscoveryProvider()
            rebuildCandidates(discovery)
            return discovery
        }
        let ghostty: Result<GhosttyDiscoveryReport, Error>
        do {
            ghostty = .success(try await ghosttyAdapter.discover())
        } catch {
            ghostty = .failure(error)
        }

        let wallpaper: Result<MacOSWallpaperDiscoveryReport, Error>
        do {
            wallpaper = .success(try await wallpaperAdapter.discover())
        } catch {
            wallpaper = .failure(error)
        }

        let starship: Result<StarshipDiscoveryReport, Error>
        do {
            starship = .success(try await starshipAdapter.discover())
        } catch {
            starship = .failure(error)
        }

        let vscode: Result<VSCodeDiscoveryReport, Error>
        do {
            vscode = .success(try await vscodeDiscovery.discover())
        } catch {
            vscode = .failure(error)
        }

        let discovery = WorkspaceTargetDiscovery(
            ghostty: ghostty,
            wallpaper: wallpaper,
            starship: starship,
            vscode: vscode
        )
        rebuildCandidates(discovery)
        return discovery
    }

    private func rebuildCandidates(_ discovery: WorkspaceTargetDiscovery) {
        var next: [TargetInstanceID: Candidate] = [:]
        let appearance = ConnectedTargetInstance(
            id: MacOSAppearanceAdapter.systemTargetInstanceID,
            displayName: "System Appearance",
            adapterID: "macos.appearance"
        )
        next[appearance.id] = Candidate(instance: appearance, vscodeInstallation: nil)

        if case .success(let report) = discovery.wallpaper {
            for display in report.displays {
                let instance = ConnectedTargetInstance(
                    id: display.targetInstanceID,
                    displayName: "Wallpaper (Display \(display.displayID))",
                    adapterID: "macos.wallpaper"
                )
                next[instance.id] = Candidate(instance: instance, vscodeInstallation: nil)
            }
        }

        if case .success(let report) = discovery.ghostty,
            report.installationStatus == .supported,
            report.configurationStatus != .ambiguous,
            report.configurationStatus != .unsupported
        {
            let instance = ConnectedTargetInstance(
                id: GhosttyConfigurationAdapter.defaultTargetInstanceID,
                displayName: "Ghostty",
                adapterID: "ghostty"
            )
            next[instance.id] = Candidate(instance: instance, vscodeInstallation: nil)
        }

        if case .success(let report) = discovery.starship,
            report.configurationStatus == .supported || report.configurationStatus == .missing
        {
            let instance = ConnectedTargetInstance(
                id: StarshipConfigurationAdapter.defaultTargetInstanceID,
                displayName: "Starship",
                adapterID: "starship"
            )
            next[instance.id] = Candidate(instance: instance, vscodeInstallation: nil)
        }

        if case .success(let report) = discovery.vscode {
            for installation in report.installations where installation.isSupported {
                let expectation = vscodeExpectation(for: installation)
                let instance = ConnectedTargetInstance(
                    id: VSCodeConnectionAdapter.targetInstanceID(for: expectation),
                    displayName: "\(installation.edition.displayName), Default profile",
                    adapterID: "vscode"
                )
                next[instance.id] = Candidate(instance: instance, vscodeInstallation: installation)
            }
        }

        for adapter in additionalAdapters {
            let instance = ConnectedTargetInstance(
                id: TargetInstanceID(rawValue: "\(adapter.id).default"),
                displayName: adapter.id.capitalized,
                adapterID: adapter.id
            )
            next[instance.id] = Candidate(instance: instance, vscodeInstallation: nil)
        }

        candidates = next
    }

    private func makeSnapshot(discovery: WorkspaceTargetDiscovery) -> WorkspaceTargetSnapshot {
        let workspace = store.workspace
        let knownPrefixes = ["macos", "ghostty", "vscode", "starship"]
        let otherConnected = workspace.connectedTargetInstances.filter { instance in
            !knownPrefixes.contains { instance.adapterID.hasPrefix($0) }
        }
        var targets = [
            macOSTarget(workspace: workspace, wallpaper: discovery.wallpaper),
            ghosttyTarget(workspace: workspace, discovery: discovery.ghostty),
            vscodeTarget(workspace: workspace, discovery: discovery.vscode),
            starshipTarget(workspace: workspace, discovery: discovery.starship),
        ]
        for instance in otherConnected {
            targets.append(
                readyTarget(
                    id: instance.adapterID,
                    name: instance.displayName,
                    image: "wrench.and.screwdriver",
                    instances: [instance]
                ))
        }
        for adapter in additionalAdapters {
            if !targets.contains(where: { $0.id == adapter.id }) {
                targets.append(additionalAdapterTarget(workspace: workspace, adapter: adapter))
            }
        }
        return WorkspaceTargetSnapshot(
            workspace: workspace,
            targets: targets
        )
    }

    private func macOSTarget(
        workspace: Workspace,
        wallpaper: Result<MacOSWallpaperDiscoveryReport, Error>
    ) -> WorkspacePresentationModel.ApplicationTarget {
        let connectedInstances = workspace.connectedTargetInstances.filter { $0.adapterID.hasPrefix("macos.") }
        let appearanceConnected = connectedInstances.contains { $0.adapterID == "macos.appearance" }

        let appearanceID = MacOSAppearanceAdapter.systemTargetInstanceID
        let appearanceOptedIn = workspace.isOptedIn(appearanceID)
        let appearanceEvaluation = RecommendedTargetPolicy.evaluate(adapterID: "macos.appearance", isAvailable: true)

        let appearanceItem = WorkspacePresentationModel.TargetInstanceItem(
            id: appearanceID,
            displayName: "System Appearance",
            detail: "Menu bar, windows, and controls theme mode",
            adapterID: "macos.appearance",
            managementState: appearanceConnected ? .connected : (appearanceOptedIn ? .setupNeeded : .notSelected),
            isOptedIn: appearanceOptedIn,
            isConnected: appearanceConnected,
            isRecommended: appearanceEvaluation.isRecommended,
            exclusionReason: appearanceEvaluation.exclusionReason,
            permissionDisclosure: MacOSAppearanceAdapter.automationPermissionDescription
        )

        var items: [WorkspacePresentationModel.TargetInstanceItem] = [appearanceItem]
        var connectionOptions: [WorkspacePresentationModel.ConnectionOption] = []

        if appearanceOptedIn, !appearanceConnected, let candidate = candidates[appearanceID] {
            connectionOptions.append(
                WorkspacePresentationModel.ConnectionOption(
                    id: candidate.instance.id,
                    name: candidate.instance.displayName,
                    detail: nil,
                    permissionDisclosure: MacOSAppearanceAdapter.automationPermissionDescription
                )
            )
        }

        let themeContainsWallpaper = desiredThemeVariant()?.wallpaper != nil

        let displaySummary: String
        switch wallpaper {
        case .success(let report):
            if report.displays.isEmpty {
                displaySummary = "No wallpaper displays discovered."
            } else {
                displaySummary =
                    "Wallpaper on \(report.displays.count) display\(report.displays.count == 1 ? "" : "s")."
                for display in report.displays {
                    let displayID = display.targetInstanceID
                    let isConnected = workspace.isConnected(displayID)
                    let isOptedIn = workspace.isOptedIn(displayID)
                    let wallpaperEval = RecommendedTargetPolicy.evaluateWallpaperDisplay(
                        isAvailable: true,
                        themeContainsWallpaper: themeContainsWallpaper
                    )
                    let item = WorkspacePresentationModel.TargetInstanceItem(
                        id: displayID,
                        displayName: "Wallpaper (Display \(display.displayID))",
                        detail: display.currentImageURL?.lastPathComponent,
                        adapterID: "macos.wallpaper",
                        managementState: isConnected ? .connected : (isOptedIn ? .setupNeeded : .notSelected),
                        isOptedIn: isOptedIn,
                        isConnected: isConnected,
                        isRecommended: wallpaperEval.isRecommended,
                        exclusionReason: wallpaperEval.exclusionReason,
                        exclusionDetail: wallpaperEval.exclusionDetail
                    )
                    items.append(item)
                    if isOptedIn, !isConnected, let candidate = candidates[displayID] {
                        connectionOptions.append(
                            WorkspacePresentationModel.ConnectionOption(
                                id: candidate.instance.id,
                                name: candidate.instance.displayName,
                                detail: display.currentImageURL?.path
                            )
                        )
                    }
                }
            }
            let discoveredIDs = Set(items.map(\.id))
            items.append(
                contentsOf: unavailablePersistedTargetItems(
                    adapterID: "macos.wallpaper",
                    detail: "The persisted display was not found in current discovery.",
                    workspace: workspace
                ).filter { !discoveredIDs.contains($0.id) }
            )
        case .failure(let error):
            displaySummary = "Wallpaper discovery failed: \(error)"
            let persistedWallpaperItems = unavailablePersistedTargetItems(
                adapterID: "macos.wallpaper",
                detail: String(describing: error),
                workspace: workspace
            )
            if persistedWallpaperItems.isEmpty {
                items.append(
                    WorkspacePresentationModel.TargetInstanceItem(
                        id: TargetInstanceID(rawValue: "macos.wallpaper.unavailable"),
                        displayName: "Wallpaper",
                        detail: String(describing: error),
                        adapterID: "macos.wallpaper",
                        managementState: .unavailable,
                        isOptedIn: false,
                        isConnected: false,
                        isRecommended: false,
                        exclusionReason: .unavailable,
                        exclusionDetail: String(describing: error)
                    )
                )
            } else {
                items.append(contentsOf: persistedWallpaperItems)
            }
        }

        let state = aggregateState(for: items)
        let summary =
            state == .needsAttention
            ? "My Mac needs attention. \(displaySummary)"
            : appearanceConnected
                ? "System Appearance connected. \(displaySummary)"
                : "Connect optional Light/Dark automation. \(displaySummary)"

        return WorkspacePresentationModel.ApplicationTarget(
            id: "macos",
            name: "macOS",
            systemImage: "macbook",
            state: state,
            summary: summary,
            instanceDetails: connectedInstances.map(\.displayName),
            connectionOptions: connectionOptions,
            instances: items
        )
    }

    private func ghosttyTarget(
        workspace: Workspace,
        discovery: Result<GhosttyDiscoveryReport, Error>
    ) -> WorkspacePresentationModel.ApplicationTarget {
        let ghosttyID = GhosttyConfigurationAdapter.defaultTargetInstanceID
        let isConnected = workspace.isConnected(ghosttyID)
        let isOptedIn = workspace.isOptedIn(ghosttyID)

        let item: WorkspacePresentationModel.TargetInstanceItem
        let options: [WorkspacePresentationModel.ConnectionOption]

        switch discovery {
        case .success(let report):
            let isAvailable =
                report.installationStatus != .missing && report.installationStatus != .unsupported
            let isAmbiguous = report.configurationStatus == .ambiguous
            let isConflicting = report.configurationStatus == .unsupported
            let recommendation = RecommendedTargetPolicy.evaluate(
                adapterID: "ghostty",
                isAvailable: isAvailable,
                isAmbiguous: isAmbiguous,
                isConflicting: isConflicting
            )
            let exclusionDetail: String?
            if !isAvailable {
                exclusionDetail = "Installation: \(report.installationStatus.rawValue)"
            } else if isAmbiguous {
                exclusionDetail = "Ambiguous configuration files detected"
            } else if isConflicting {
                exclusionDetail = "Configuration is unsupported"
            } else {
                exclusionDetail = nil
            }

            let state = targetManagementState(
                isConnected: isConnected,
                isOptedIn: isOptedIn,
                isAvailable: isAvailable,
                hasKnownProblem: isAmbiguous || isConflicting
            )

            item = WorkspacePresentationModel.TargetInstanceItem(
                id: ghosttyID,
                displayName: "Ghostty",
                detail: report.resolvedConfigurationURL?.path,
                adapterID: "ghostty",
                managementState: state,
                isOptedIn: isOptedIn,
                isConnected: isConnected,
                isRecommended: recommendation.isRecommended,
                exclusionReason: recommendation.exclusionReason,
                exclusionDetail: exclusionDetail
            )

            if isOptedIn, !isConnected, isAvailable, !isAmbiguous, !isConflicting,
                let candidate = candidates[ghosttyID]
            {
                options = [
                    WorkspacePresentationModel.ConnectionOption(
                        id: candidate.instance.id,
                        name: candidate.instance.displayName,
                        detail: report.resolvedConfigurationURL?.path
                    )
                ]
            } else {
                options = []
            }

            return WorkspacePresentationModel.ApplicationTarget(
                id: "ghostty",
                name: "Ghostty",
                systemImage: "terminal",
                state: state,
                summary:
                    state == .needsAttention
                    ? (exclusionDetail ?? "Ghostty needs attention.")
                    : isConnected
                        ? "Connected"
                        : (isAvailable
                            ? "Review a managed config fragment and documented reload before connecting."
                            : "Installation: \(report.installationStatus.rawValue). Configuration: \(report.configurationStatus.rawValue)."),
                instanceDetails: report.configurationCandidates.map(\.path),
                connectionOptions: options,
                instances: [item]
            )

        case .failure(let error):
            item = WorkspacePresentationModel.TargetInstanceItem(
                id: ghosttyID,
                displayName: "Ghostty",
                detail: String(describing: error),
                adapterID: "ghostty",
                managementState: targetManagementState(
                    isConnected: isConnected,
                    isOptedIn: isOptedIn,
                    isAvailable: false,
                    hasKnownProblem: true
                ),
                isOptedIn: isOptedIn,
                isConnected: isConnected,
                isRecommended: false,
                exclusionReason: .unavailable,
                exclusionDetail: String(describing: error)
            )
            return WorkspacePresentationModel.ApplicationTarget(
                id: "ghostty",
                name: "Ghostty",
                systemImage: "terminal",
                state: item.managementState,
                summary: String(describing: error),
                instanceDetails: [],
                connectionOptions: [],
                instances: [item]
            )
        }
    }

    private func vscodeTarget(
        workspace: Workspace,
        discovery: Result<VSCodeDiscoveryReport, Error>
    ) -> WorkspacePresentationModel.ApplicationTarget {
        guard vscodePlatform != nil, vscodeArtifact != nil else {
            return unavailableApplicationTarget(
                id: "vscode",
                name: "Visual Studio Code",
                image: "chevron.left.forwardslash.chevron.right",
                adapterID: "vscode",
                fallbackID: TargetInstanceID(rawValue: "vscode.unavailable"),
                detail: vscodeStartupFailure ?? "The pinned companion could not start.",
                workspace: workspace
            )
        }

        switch discovery {
        case .success(let report):
            if report.installations.isEmpty {
                return unavailableApplicationTarget(
                    id: "vscode",
                    name: "Visual Studio Code",
                    image: "chevron.left.forwardslash.chevron.right",
                    adapterID: "vscode",
                    fallbackID: TargetInstanceID(rawValue: "vscode.none"),
                    detail: report.detail ?? "No supported Microsoft VS Code installation was found.",
                    workspace: workspace
                )
            }

            var items: [WorkspacePresentationModel.TargetInstanceItem] = []
            var options: [WorkspacePresentationModel.ConnectionOption] = []

            for installation in report.installations {
                let expectation = vscodeExpectation(for: installation)
                let id = VSCodeConnectionAdapter.targetInstanceID(for: expectation)
                let isConnected = workspace.isConnected(id)
                let isOptedIn = workspace.isOptedIn(id)

                let isSupported = installation.isSupported
                let isAmbiguous = report.status == .ambiguous
                let recommendation = RecommendedTargetPolicy.evaluate(
                    adapterID: "vscode",
                    isAvailable: isSupported,
                    isAmbiguous: isAmbiguous
                )

                let state = targetManagementState(
                    isConnected: isConnected,
                    isOptedIn: isOptedIn,
                    isAvailable: isSupported,
                    hasKnownProblem: isAmbiguous
                )

                let exclusionDetail: String? =
                    !isSupported
                    ? "VS Code version \(installation.version) is unsupported"
                    : (isAmbiguous ? "Ambiguous installation or configuration" : nil)

                let item = WorkspacePresentationModel.TargetInstanceItem(
                    id: id,
                    displayName: "\(installation.edition.displayName), Default profile",
                    detail: "\(installation.version) at \(installation.bundleURL.path)",
                    adapterID: "vscode",
                    managementState: state,
                    isOptedIn: isOptedIn,
                    isConnected: isConnected,
                    isRecommended: recommendation.isRecommended,
                    exclusionReason: recommendation.exclusionReason,
                    exclusionDetail: exclusionDetail
                )
                items.append(item)

                if isOptedIn, isSupported, !isAmbiguous, !isConnected,
                    let candidate = candidates[id]
                {
                    options.append(
                        WorkspacePresentationModel.ConnectionOption(
                            id: candidate.instance.id,
                            name: "\(installation.edition.displayName), Default profile",
                            detail: "\(installation.version) at \(installation.bundleURL.path)"
                        )
                    )
                }
            }

            let discoveredIDs = Set(items.map(\.id))
            items.append(
                contentsOf: unavailablePersistedTargetItems(
                    adapterID: "vscode",
                    detail: "The persisted Target Instance was not found in current discovery.",
                    workspace: workspace
                ).filter { !discoveredIDs.contains($0.id) }
            )

            let state = aggregateState(for: items)
            let summary =
                state == .needsAttention
                ? (items.compactMap(\.exclusionDetail).first ?? "Visual Studio Code needs attention.")
                : state == .connected
                    ? "Default profile connected. Keep VS Code open for current-window activation."
                    : (options.count == 1
                        ? "Install or verify the pinned companion for the Default profile."
                        : "Choose which VS Code edition should join My Mac.")

            return WorkspacePresentationModel.ApplicationTarget(
                id: "vscode",
                name: "Visual Studio Code",
                systemImage: "chevron.left.forwardslash.chevron.right",
                state: state,
                summary: summary,
                instanceDetails: report.installations.map {
                    "\($0.edition.displayName) \($0.version), \($0.bundleURL.path)"
                },
                connectionOptions: options,
                instances: items
            )

        case .failure(let error):
            return unavailableApplicationTarget(
                id: "vscode",
                name: "Visual Studio Code",
                image: "chevron.left.forwardslash.chevron.right",
                adapterID: "vscode",
                fallbackID: TargetInstanceID(rawValue: "vscode.failure"),
                detail: String(describing: error),
                workspace: workspace
            )
        }
    }

    private func starshipTarget(
        workspace: Workspace,
        discovery: Result<StarshipDiscoveryReport, Error>
    ) -> WorkspacePresentationModel.ApplicationTarget {
        let starshipID = StarshipConfigurationAdapter.defaultTargetInstanceID
        let isConnected = workspace.isConnected(starshipID)
        let isOptedIn = workspace.isOptedIn(starshipID)

        switch discovery {
        case .success(let report):
            let isAmbiguous = report.configurationStatus == .ambiguous || report.configurationStatus == .malformed
            let isConflicting = report.configurationStatus == .unsupported
            let recommendation = RecommendedTargetPolicy.evaluate(
                adapterID: "starship",
                isAvailable: true,
                isAmbiguous: isAmbiguous,
                isConflicting: isConflicting
            )
            let exclusionDetail: String? =
                isAmbiguous
                ? (report.detail ?? "Configuration is \(report.configurationStatus.rawValue).")
                : (isConflicting ? (report.detail ?? "Unsupported configuration") : nil)

            let state = targetManagementState(
                isConnected: isConnected,
                isOptedIn: isOptedIn,
                isAvailable: true,
                hasKnownProblem: isAmbiguous || isConflicting
            )

            let item = WorkspacePresentationModel.TargetInstanceItem(
                id: starshipID,
                displayName: "Starship",
                detail: report.resolvedConfigurationURL?.path,
                adapterID: "starship",
                managementState: state,
                isOptedIn: isOptedIn,
                isConnected: isConnected,
                isRecommended: recommendation.isRecommended,
                exclusionReason: recommendation.exclusionReason,
                exclusionDetail: exclusionDetail
            )

            var options: [WorkspacePresentationModel.ConnectionOption] = []
            if isOptedIn, !isConnected, !isAmbiguous, !isConflicting,
                let candidate = candidates[starshipID]
            {
                options.append(
                    WorkspacePresentationModel.ConnectionOption(
                        id: candidate.instance.id,
                        name: candidate.instance.displayName,
                        detail: report.resolvedConfigurationURL?.path
                    )
                )
            }

            return WorkspacePresentationModel.ApplicationTarget(
                id: "starship",
                name: "Starship",
                systemImage: "sparkles",
                state: state,
                summary:
                    state == .needsAttention
                    ? (exclusionDetail ?? "Starship needs attention.")
                    : isConnected
                        ? "Connected"
                        : "Manage only registered palette keys. Changes appear at the next prompt.",
                instanceDetails: report.configurationCandidates.map(\.path),
                connectionOptions: options,
                instances: [item]
            )

        case .failure(let error):
            let item = WorkspacePresentationModel.TargetInstanceItem(
                id: starshipID,
                displayName: "Starship",
                detail: String(describing: error),
                adapterID: "starship",
                managementState: targetManagementState(
                    isConnected: isConnected,
                    isOptedIn: isOptedIn,
                    isAvailable: false,
                    hasKnownProblem: true
                ),
                isOptedIn: isOptedIn,
                isConnected: isConnected,
                isRecommended: false,
                exclusionReason: .unavailable,
                exclusionDetail: String(describing: error)
            )
            return WorkspacePresentationModel.ApplicationTarget(
                id: "starship",
                name: "Starship",
                systemImage: "sparkles",
                state: item.managementState,
                summary: String(describing: error),
                instanceDetails: [],
                connectionOptions: [],
                instances: [item]
            )
        }
    }

    private func additionalAdapterTarget(
        workspace: Workspace,
        adapter: any ThemeAdapter
    ) -> WorkspacePresentationModel.ApplicationTarget {
        let instanceID = TargetInstanceID(rawValue: "\(adapter.id).default")
        let isConnected = workspace.isConnected(instanceID)
        let isOptedIn = workspace.isOptedIn(instanceID)
        let isExperimental = experimentalAdapterIDs.contains(adapter.id)
        let recommendation = RecommendedTargetPolicy.evaluate(
            adapterID: adapter.id,
            isAvailable: true,
            isExperimental: isExperimental
        )
        let exclusionDetail =
            isExperimental
            ? "Experimental adapter"
            : "Adapter '\(adapter.id)' is not in the stable adapter allowlist"

        let state: TargetManagementState =
            isConnected
            ? .connected
            : (isOptedIn ? .setupNeeded : .notSelected)

        let item = WorkspacePresentationModel.TargetInstanceItem(
            id: instanceID,
            displayName: adapter.id.capitalized,
            adapterID: adapter.id,
            managementState: state,
            isOptedIn: isOptedIn,
            isConnected: isConnected,
            isRecommended: recommendation.isRecommended,
            exclusionReason: recommendation.exclusionReason,
            exclusionDetail: exclusionDetail
        )

        return WorkspacePresentationModel.ApplicationTarget(
            id: adapter.id,
            name: adapter.id.capitalized,
            systemImage: "wrench.and.screwdriver",
            state: state,
            summary: isConnected ? "Connected" : exclusionDetail,
            instanceDetails: [instanceID.rawValue],
            connectionOptions: isConnected || !isOptedIn
                ? []
                : [
                    WorkspacePresentationModel.ConnectionOption(
                        id: instanceID,
                        name: adapter.id.capitalized,
                        detail: nil
                    )
                ],
            instances: [item]
        )
    }

    private func readyTarget(
        id: String,
        name: String,
        image: String,
        instances: [ConnectedTargetInstance],
        summary: String = "Connected"
    ) -> WorkspacePresentationModel.ApplicationTarget {
        let items = instances.map { instance in
            WorkspacePresentationModel.TargetInstanceItem(
                id: instance.id,
                displayName: instance.displayName,
                adapterID: instance.adapterID,
                managementState: .connected,
                isOptedIn: true,
                isConnected: true,
                isRecommended: RecommendedTargetPolicy.isAllowlisted(adapterID: instance.adapterID)
            )
        }
        return WorkspacePresentationModel.ApplicationTarget(
            id: id,
            name: name,
            systemImage: image,
            state: .connected,
            summary: summary,
            instanceDetails: instances.map(\.displayName),
            connectionOptions: [],
            instances: items
        )
    }

    private func unavailableApplicationTarget(
        id: String,
        name: String,
        image: String,
        adapterID: String,
        fallbackID: TargetInstanceID,
        detail: String,
        workspace: Workspace
    ) -> WorkspacePresentationModel.ApplicationTarget {
        let persistedInstances = unavailablePersistedTargetItems(
            adapterID: adapterID,
            detail: detail,
            workspace: workspace
        )
        let instances: [WorkspacePresentationModel.TargetInstanceItem]
        if persistedInstances.isEmpty {
            instances = [
                WorkspacePresentationModel.TargetInstanceItem(
                    id: fallbackID,
                    displayName: name,
                    detail: detail,
                    adapterID: adapterID,
                    managementState: .unavailable,
                    isOptedIn: false,
                    isConnected: false,
                    isRecommended: false,
                    exclusionReason: .unavailable,
                    exclusionDetail: detail
                )
            ]
        } else {
            instances = persistedInstances
        }
        return WorkspacePresentationModel.ApplicationTarget(
            id: id,
            name: name,
            systemImage: image,
            state: aggregateState(for: instances),
            summary: detail,
            instanceDetails: instances.map(\.displayName),
            connectionOptions: [],
            instances: instances
        )
    }

    private func unavailablePersistedTargetItems(
        adapterID: String,
        detail: String,
        workspace: Workspace
    ) -> [WorkspacePresentationModel.TargetInstanceItem] {
        var items: [WorkspacePresentationModel.TargetInstanceItem] = []
        var seenIDs = Set<TargetInstanceID>()

        for instance in store.targetInstances where instance.adapterID == adapterID {
            seenIDs.insert(instance.id)
            let isConnected = workspace.isConnected(instance.id)
            let isOptedIn = workspace.isOptedIn(instance.id)
            items.append(
                WorkspacePresentationModel.TargetInstanceItem(
                    id: instance.id,
                    displayName: instance.displayName,
                    detail: detail,
                    adapterID: instance.adapterID,
                    managementState: targetManagementState(
                        isConnected: isConnected,
                        isOptedIn: isOptedIn,
                        isAvailable: false,
                        hasKnownProblem: true
                    ),
                    isOptedIn: isOptedIn,
                    isConnected: isConnected,
                    isRecommended: false,
                    exclusionReason: .unavailable,
                    exclusionDetail: detail
                )
            )
        }

        for connected in workspace.connectedTargetInstances
        where connected.adapterID == adapterID && !seenIDs.contains(connected.id) {
            seenIDs.insert(connected.id)
            items.append(
                WorkspacePresentationModel.TargetInstanceItem(
                    id: connected.id,
                    displayName: connected.displayName,
                    detail: detail,
                    adapterID: connected.adapterID,
                    managementState: .needsAttention,
                    isOptedIn: true,
                    isConnected: true,
                    isRecommended: false,
                    exclusionReason: .unavailable,
                    exclusionDetail: detail
                )
            )
        }

        return items
    }

    private func desiredThemeVariant() -> ThemeVariant? {
        guard let assignment = workspace.themeAssignment else { return nil }
        let variantID: String
        switch assignment {
        case .fixed(let fixedVariantID):
            variantID = fixedVariantID
        case .appearancePair(let lightVariantID, let darkVariantID):
            variantID = currentThemeAppearanceProvider() == .dark ? darkVariantID : lightVariantID
        }
        return themePacks.lazy
            .flatMap(\.variants)
            .first { $0.qualifiedID == variantID }
    }

    private func targetManagementState(
        isConnected: Bool,
        isOptedIn: Bool,
        isAvailable: Bool,
        hasKnownProblem: Bool = false
    ) -> TargetManagementState {
        if (isConnected || isOptedIn) && (!isAvailable || hasKnownProblem) {
            return .needsAttention
        }
        if isConnected {
            return .connected
        }
        if isOptedIn {
            return .setupNeeded
        }
        return isAvailable ? .notSelected : .unavailable
    }

    private func aggregateState(
        for instances: [WorkspacePresentationModel.TargetInstanceItem]
    ) -> TargetManagementState {
        if instances.contains(where: { $0.managementState == .needsAttention }) {
            return .needsAttention
        }
        if instances.contains(where: { $0.managementState == .connected }) {
            return .connected
        }
        if instances.contains(where: { $0.managementState == .setupNeeded }) {
            return .setupNeeded
        }
        if instances.contains(where: { $0.managementState == .notSelected }) {
            return .notSelected
        }
        return .unavailable
    }

    private func registerAdapterForPersistedVSCodeTarget(
        from discovery: Result<VSCodeDiscoveryReport, Error>
    ) async {
        guard let target = store.targetInstances.first(where: { $0.adapterID == "vscode" }),
            case .success(let report) = discovery,
            let installation = report.installations.first(where: {
                target.id.rawValue.contains(":\($0.edition.rawValue):")
            }),
            let themeEngine
        else { return }
        guard let adapter = try? makeVSCodeAdapter(for: installation) else { return }
        await themeEngine.register(adapter: adapter)
    }

    private func makeVSCodeAdapter(for installation: VSCodeInstallation) throws -> VSCodeConnectionAdapter {
        guard let vscodePlatform, let vscodeArtifact else {
            throw ProductionWorkspaceRuntimeError.vscodeCompanionUnavailable
        }
        return VSCodeConnectionAdapter(
            platform: vscodePlatform,
            artifact: vscodeArtifact,
            selectedBundleURL: installation.bundleURL,
            selectedProfileName: Constants.vscodeProfileName,
            expectedRegistration: vscodeExpectation(for: installation)
        )
    }

    private func vscodeExpectation(for installation: VSCodeInstallation) -> VSCodeRegistrationExpectation {
        VSCodeRegistrationExpectation(
            scope: .profile,
            edition: installation.edition,
            applicationVersion: installation.version,
            extensionVersion: Constants.companionVersion,
            profileName: Constants.vscodeProfileName
        )
    }

    static func startVSCodeCompanion() throws -> VSCodeCompanionRuntime? {
        guard
            let vsixURL = Bundle.main.url(
                forResource: "oh-my-theme-companion-0.1.0",
                withExtension: "vsix"
            )
        else {
            throw ProductionWorkspaceRuntimeError.missingVSCodeCompanion
        }
        let launchID = UUID().uuidString
        let paths = try CompanionSocketPaths.production(launchID: launchID)
        let companionServer = CompanionSocketServer(
            configuration: CompanionSocketServerConfiguration(
                paths: paths,
                launchID: launchID,
                launchNonce: UUID().uuidString
            )
        )
        try companionServer.start()
        return VSCodeCompanionRuntime(
            server: companionServer,
            platform: SystemVSCodeConnectionPlatform(server: companionServer),
            artifact: VSCodeCompanionArtifact(
                extensionID: Constants.companionExtensionID,
                version: Constants.companionVersion,
                vsixURL: vsixURL,
                sha256: Constants.companionSHA256
            )
        )
    }

    private static func xdgConfigHome() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
            path.hasPrefix("/")
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

enum ProductionWorkspaceRuntimeError: Error, Equatable {
    case missingVSCodeCompanion
    case vscodeCompanionUnavailable
    case targetNoLongerAvailable(TargetInstanceID)
    case targetNotOptedIn(TargetInstanceID)
    case engineUnavailable(String)
    case cannotOptOutConnectedTarget(TargetInstanceID)
    case setupPlanInvalidated(String)
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
