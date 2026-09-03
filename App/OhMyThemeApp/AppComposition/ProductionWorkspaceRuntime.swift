import Adapters
import Foundation
import PlatformClients
import ThemeEngine
import ThemeModel

@MainActor
final class ProductionWorkspaceRuntime: WorkspaceRuntime {
    private enum Constants {
        static let companionExtensionID = "ohmytheme.oh-my-theme-companion"
        static let companionVersion = "0.1.0"
        static let companionSHA256 = "8e444eff4be3d6b7f9cc16fde6fe573dffa7c5a62088e1b4cf9f594627e34427"
        static let vscodeProfileName = "Default"
    }

    private struct Candidate {
        let instance: ConnectedTargetInstance
        let vscodeInstallation: VSCodeInstallation?
    }

    private let store: WorkspaceStore
    private let appearanceAdapter: MacOSAppearanceAdapter
    private let wallpaperAdapter: MacOSWallpaperAdapter
    private let ghosttyAdapter: GhosttyConfigurationAdapter
    private let starshipAdapter: StarshipConfigurationAdapter
    private let vscodeDiscovery: VSCodeApplicationDiscovery
    private let vscodePlatform: SystemVSCodeConnectionPlatform?
    private let vscodeArtifact: VSCodeCompanionArtifact?
    private let socketServer: CompanionSocketServer?
    private var candidates: [TargetInstanceID: Candidate] = [:]
    private var fatalStartupFailure: String?
    private var vscodeStartupFailure: String?

    let themePacks: [ThemePack]
    let themeEngine: ThemeEngine?

    var workspace: Workspace { store.workspace }

    var persistenceError: String? {
        [store.persistenceError, fatalStartupFailure]
            .compactMap { $0 }
            .joined(separator: " ")
            .nilIfEmpty
    }

    init(store: WorkspaceStore = WorkspaceStore()) {
        self.store = store
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

        do {
            themePacks = try BundledThemeCatalog().load()
        } catch {
            themePacks = []
            fatalStartupFailure = "Bundled Theme Catalog validation failed: \(error)"
        }

        var server: CompanionSocketServer?
        var platform: SystemVSCodeConnectionPlatform?
        var artifact: VSCodeCompanionArtifact?
        do {
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
            server = companionServer
            platform = SystemVSCodeConnectionPlatform(server: companionServer)
            artifact = VSCodeCompanionArtifact(
                extensionID: Constants.companionExtensionID,
                version: Constants.companionVersion,
                vsixURL: vsixURL,
                sha256: Constants.companionSHA256
            )
        } catch {
            vscodeStartupFailure = "VS Code companion unavailable: \(error)"
        }
        socketServer = server
        vscodePlatform = platform
        vscodeArtifact = artifact

        guard !themePacks.isEmpty else {
            themeEngine = nil
            return
        }
        themeEngine = ThemeEngine(
            packs: themePacks,
            adapters: [appearanceAdapter, wallpaperAdapter, ghosttyAdapter, starshipAdapter],
            sourcePolicy: .preferUpstream,
            persistence: store.persistenceStore
        )
    }

    deinit {
        socketServer?.stop()
    }

    func selectFixedThemeVariant(_ variantID: String) {
        store.selectFixedVariant(variantID)
    }

    func start() async throws -> WorkspaceTargetSnapshot {
        guard let themeEngine else {
            throw ProductionWorkspaceRuntimeError.engineUnavailable(
                fatalStartupFailure ?? "ThemeEngine is unavailable.")
        }
        let discovery = await discoverTargets()
        await registerAdapterForPersistedVSCodeTarget(from: discovery.vscode)
        try await themeEngine.reconcileInterruptedOperations()
        return makeSnapshot(discovery: discovery)
    }

    func reviewConnection(optionID: TargetInstanceID) async throws -> ConnectionPlan {
        guard let themeEngine else {
            throw ProductionWorkspaceRuntimeError.engineUnavailable(
                fatalStartupFailure ?? "ThemeEngine is unavailable.")
        }
        _ = await discoverTargets()
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
        guard let themeEngine else {
            throw ProductionWorkspaceRuntimeError.engineUnavailable(
                fatalStartupFailure ?? "ThemeEngine is unavailable.")
        }
        var discovery = await discoverTargets()
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
        let connected = report.outcomes.contains {
            $0.configurationState == .updated || $0.configurationState == .unchanged
        }
        if connected {
            discovery = await discoverTargets()
        }
        return WorkspaceConnectionResult(
            snapshot: makeSnapshot(discovery: discovery),
            report: report
        )
    }

    private struct Discovery {
        let ghostty: Result<GhosttyDiscoveryReport, Error>
        let wallpaper: Result<MacOSWallpaperDiscoveryReport, Error>
        let starship: Result<StarshipDiscoveryReport, Error>
        let vscode: Result<VSCodeDiscoveryReport, Error>
    }

    private func discoverTargets() async -> Discovery {
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

        let discovery = Discovery(
            ghostty: ghostty,
            wallpaper: wallpaper,
            starship: starship,
            vscode: vscode
        )
        rebuildCandidates(discovery)
        return discovery
    }

    private func rebuildCandidates(_ discovery: Discovery) {
        var next: [TargetInstanceID: Candidate] = [:]
        let appearance = ConnectedTargetInstance(
            id: MacOSAppearanceAdapter.systemTargetInstanceID,
            displayName: "System Appearance",
            adapterID: "macos.appearance"
        )
        next[appearance.id] = Candidate(instance: appearance, vscodeInstallation: nil)

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
        candidates = next
    }

    private func makeSnapshot(discovery: Discovery) -> WorkspaceTargetSnapshot {
        let workspace = store.workspace
        return WorkspaceTargetSnapshot(
            workspace: workspace,
            targets: [
                macOSTarget(workspace: workspace, wallpaper: discovery.wallpaper),
                ghosttyTarget(workspace: workspace, discovery: discovery.ghostty),
                vscodeTarget(workspace: workspace, discovery: discovery.vscode),
                starshipTarget(workspace: workspace, discovery: discovery.starship),
            ]
        )
    }

    private func macOSTarget(
        workspace: Workspace,
        wallpaper: Result<MacOSWallpaperDiscoveryReport, Error>
    ) -> WorkspaceMenuModel.ApplicationTarget {
        let instances = workspace.connectedTargetInstances.filter { $0.adapterID.hasPrefix("macos.") }
        let appearanceConnected = instances.contains { $0.adapterID == "macos.appearance" }
        let displaySummary: String
        switch wallpaper {
        case .success(let report):
            displaySummary =
                report.displays.isEmpty
                ? "No wallpaper displays discovered."
                : "Wallpaper stays unchanged on \(report.displays.count) display\(report.displays.count == 1 ? "" : "s")."
        case .failure(let error):
            displaySummary = "Wallpaper discovery failed: \(error)"
        }
        let option = candidates[MacOSAppearanceAdapter.systemTargetInstanceID].map {
            WorkspaceMenuModel.ConnectionOption(
                id: $0.instance.id,
                name: $0.instance.displayName,
                detail: nil,
                permissionDisclosure: MacOSAppearanceAdapter.automationPermissionDescription
            )
        }
        return WorkspaceMenuModel.ApplicationTarget(
            id: "macos",
            name: "macOS",
            systemImage: "macbook",
            state: appearanceConnected ? .ready : .setupNeeded,
            summary: appearanceConnected
                ? "System Appearance connected. \(displaySummary)"
                : "Connect optional Light/Dark automation. \(displaySummary)",
            instanceDetails: instances.map(\.displayName),
            connectionOptions: appearanceConnected ? [] : option.map { [$0] } ?? []
        )
    }

    private func ghosttyTarget(
        workspace: Workspace,
        discovery: Result<GhosttyDiscoveryReport, Error>
    ) -> WorkspaceMenuModel.ApplicationTarget {
        let connected = workspace.connectedTargetInstances.filter { $0.adapterID == "ghostty" }
        if !connected.isEmpty {
            return readyTarget(id: "ghostty", name: "Ghostty", image: "terminal", instances: connected)
        }
        switch discovery {
        case .success(let report):
            if let candidate = candidates[GhosttyConfigurationAdapter.defaultTargetInstanceID] {
                return WorkspaceMenuModel.ApplicationTarget(
                    id: "ghostty",
                    name: "Ghostty",
                    systemImage: "terminal",
                    state: .setupNeeded,
                    summary: "Review a managed config fragment and documented reload before connecting.",
                    instanceDetails: report.configurationCandidates.map(\.path),
                    connectionOptions: [
                        .init(
                            id: candidate.instance.id,
                            name: candidate.instance.displayName,
                            detail: report.resolvedConfigurationURL?.path
                        )
                    ]
                )
            }
            return unavailableTarget(
                id: "ghostty",
                name: "Ghostty",
                image: "terminal",
                detail:
                    "Installation: \(report.installationStatus.rawValue). Configuration: \(report.configurationStatus.rawValue).",
                instances: report.installations.map { "\($0.executableURL.path), \($0.version)" }
                    + report.configurationCandidates.map(\.path)
            )
        case .failure(let error):
            return unavailableTarget(
                id: "ghostty", name: "Ghostty", image: "terminal", detail: String(describing: error))
        }
    }

    private func vscodeTarget(
        workspace: Workspace,
        discovery: Result<VSCodeDiscoveryReport, Error>
    ) -> WorkspaceMenuModel.ApplicationTarget {
        let connected = workspace.connectedTargetInstances.filter { $0.adapterID == "vscode" }
        if !connected.isEmpty {
            return readyTarget(
                id: "vscode",
                name: "Visual Studio Code",
                image: "chevron.left.forwardslash.chevron.right",
                instances: connected,
                summary: "Default profile connected. Keep VS Code open for current-window activation."
            )
        }
        guard vscodePlatform != nil, vscodeArtifact != nil else {
            return unavailableTarget(
                id: "vscode",
                name: "Visual Studio Code",
                image: "chevron.left.forwardslash.chevron.right",
                detail: vscodeStartupFailure ?? "The pinned companion could not start."
            )
        }
        switch discovery {
        case .success(let report):
            let options = report.installations.filter(\.isSupported).compactMap { installation in
                let expectation = vscodeExpectation(for: installation)
                let id = VSCodeConnectionAdapter.targetInstanceID(for: expectation)
                return candidates[id].map { _ in
                    WorkspaceMenuModel.ConnectionOption(
                        id: id,
                        name: "\(installation.edition.displayName), Default profile",
                        detail: "\(installation.version) at \(installation.bundleURL.path)"
                    )
                }
            }
            if !options.isEmpty {
                return WorkspaceMenuModel.ApplicationTarget(
                    id: "vscode",
                    name: "Visual Studio Code",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    state: .setupNeeded,
                    summary: options.count == 1
                        ? "Install or verify the pinned companion for the Default profile."
                        : "Choose which VS Code edition should join My Mac.",
                    instanceDetails: report.installations.map {
                        "\($0.edition.displayName) \($0.version), \($0.bundleURL.path)"
                    },
                    connectionOptions: options
                )
            }
            return unavailableTarget(
                id: "vscode",
                name: "Visual Studio Code",
                image: "chevron.left.forwardslash.chevron.right",
                detail: report.detail ?? "No supported Microsoft VS Code installation was found.",
                instances: report.installations.map {
                    "\($0.edition.displayName) \($0.version), \($0.bundleURL.path)"
                }
            )
        case .failure(let error):
            return unavailableTarget(
                id: "vscode",
                name: "Visual Studio Code",
                image: "chevron.left.forwardslash.chevron.right",
                detail: String(describing: error)
            )
        }
    }

    private func starshipTarget(
        workspace: Workspace,
        discovery: Result<StarshipDiscoveryReport, Error>
    ) -> WorkspaceMenuModel.ApplicationTarget {
        let connected = workspace.connectedTargetInstances.filter { $0.adapterID == "starship" }
        if !connected.isEmpty {
            return readyTarget(id: "starship", name: "Starship", image: "sparkles", instances: connected)
        }
        switch discovery {
        case .success(let report):
            if let candidate = candidates[StarshipConfigurationAdapter.defaultTargetInstanceID] {
                return WorkspaceMenuModel.ApplicationTarget(
                    id: "starship",
                    name: "Starship",
                    systemImage: "sparkles",
                    state: .setupNeeded,
                    summary: "Manage only registered palette keys. Changes appear at the next prompt.",
                    instanceDetails: report.configurationCandidates.map(\.path),
                    connectionOptions: [
                        .init(
                            id: candidate.instance.id,
                            name: candidate.instance.displayName,
                            detail: report.resolvedConfigurationURL?.path
                        )
                    ]
                )
            }
            return unavailableTarget(
                id: "starship",
                name: "Starship",
                image: "sparkles",
                detail: report.detail ?? "Configuration is \(report.configurationStatus.rawValue).",
                instances: report.configurationCandidates.map(\.path)
            )
        case .failure(let error):
            return unavailableTarget(
                id: "starship", name: "Starship", image: "sparkles", detail: String(describing: error))
        }
    }

    private func readyTarget(
        id: String,
        name: String,
        image: String,
        instances: [ConnectedTargetInstance],
        summary: String = "Connected"
    ) -> WorkspaceMenuModel.ApplicationTarget {
        WorkspaceMenuModel.ApplicationTarget(
            id: id,
            name: name,
            systemImage: image,
            state: .ready,
            summary: summary,
            instanceDetails: instances.map(\.displayName),
            connectionOptions: []
        )
    }

    private func unavailableTarget(
        id: String,
        name: String,
        image: String,
        detail: String,
        instances: [String] = []
    ) -> WorkspaceMenuModel.ApplicationTarget {
        WorkspaceMenuModel.ApplicationTarget(
            id: id,
            name: name,
            systemImage: image,
            state: .unavailable,
            summary: detail,
            instanceDetails: instances,
            connectionOptions: []
        )
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
    case engineUnavailable(String)
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
