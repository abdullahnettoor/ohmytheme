import CryptoKit
import Foundation
import Persistence
import PlatformClients
import ThemeModel

// MARK: - Discovery

public enum StarshipInstallationStatus: String, Codable, Equatable, Sendable {
    case missing
    case supported
}

public enum StarshipConfigurationStatus: String, Codable, Equatable, Sendable {
    case missing
    case supported
    case malformed
    case ambiguous
    case unsupported
}

public struct StarshipDiscoveryReport: Codable, Equatable, Sendable {
    public let configurationCandidates: [URL]
    public let resolvedConfigurationURL: URL?
    public let configurationStatus: StarshipConfigurationStatus
    public let ownership: ManagedFileOwnership?
    public let detail: String?

    public init(
        configurationCandidates: [URL],
        resolvedConfigurationURL: URL?,
        configurationStatus: StarshipConfigurationStatus,
        ownership: ManagedFileOwnership? = nil,
        detail: String? = nil
    ) {
        self.configurationCandidates = configurationCandidates
        self.resolvedConfigurationURL = resolvedConfigurationURL
        self.configurationStatus = configurationStatus
        self.ownership = ownership
        self.detail = detail
    }
}

public struct StarshipConfigurationLocator: Sendable {
    public let homeDirectory: URL
    public let xdgConfigHome: URL

    public init(homeDirectory: URL, xdgConfigHome: URL? = nil) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.xdgConfigHome = (xdgConfigHome ?? homeDirectory.appendingPathComponent(".config")).standardizedFileURL
    }

    public var candidates: [URL] {
        // Standard Starship location: $XDG_CONFIG_HOME/starship.toml (defaults to ~/.config/starship.toml)
        // Also check legacy ~/.config/starship.toml explicitly
        let xdg = xdgConfigHome.appendingPathComponent("starship.toml")
        let homeConfig = homeDirectory.appendingPathComponent(".config/starship.toml")
        if xdg.standardizedFileURL == homeConfig.standardizedFileURL {
            return [xdg]
        }
        return [homeConfig, xdg]
    }

    public var defaultURL: URL {
        xdgConfigHome.appendingPathComponent("starship.toml")
    }
}

// MARK: - Errors

public enum StarshipAdapterError: Error, Equatable, Sendable {
    case configurationUnavailable(StarshipConfigurationStatus)
    case managedByNix(URL)
    case linkedSourceApprovalRequired(URL)
    case malformedConfiguration(String)
    case ambiguousConfiguration(String)
    case malformedPlan
    case staleState
    case restorationConflict
    case filesystemFailure(String)
    case notConnected(URL)
}

// MARK: - Payloads

public struct StarshipConnectionDetails: Codable, Equatable, Sendable {
    public let resolvedConfigURL: URL
    public let resolvedConfigPermissions: UInt16
    public let linkedSourceURL: URL?
    public let expectedReach: String

    public init(
        resolvedConfigURL: URL,
        resolvedConfigPermissions: UInt16,
        linkedSourceURL: URL?,
        expectedReach: String
    ) {
        self.resolvedConfigURL = resolvedConfigURL
        self.resolvedConfigPermissions = resolvedConfigPermissions
        self.linkedSourceURL = linkedSourceURL
        self.expectedReach = expectedReach
    }
}

public struct StarshipConnectionPayload: Codable, Equatable, Sendable {
    public let details: StarshipConnectionDetails
    public let filePlan: ManagedFilePlan?

    public init(details: StarshipConnectionDetails, filePlan: ManagedFilePlan? = nil) {
        self.details = details
        self.filePlan = filePlan
    }
}

public struct StarshipConnectionBaseline: Codable, Equatable, Sendable {
    public let inspection: ManagedFileInspection
    public let approvedLinkedSourceURL: URL?

    public init(
        inspection: ManagedFileInspection,
        approvedLinkedSourceURL: URL? = nil
    ) {
        self.inspection = inspection
        self.approvedLinkedSourceURL = approvedLinkedSourceURL
    }
}

public struct StarshipDisconnectPayload: Codable, Equatable, Sendable {
    public let details: StarshipConnectionDetails
    public let restorationReceipt: ManagedFileReceipt

    public init(details: StarshipConnectionDetails, restorationReceipt: ManagedFileReceipt) {
        self.details = details
        self.restorationReceipt = restorationReceipt
    }
}

private struct StarshipThemeState: Codable {
    let details: StarshipConnectionDetails
    let before: ManagedFileInspection
    let filePlan: ManagedFilePlan
}

// MARK: - Adapter

public actor StarshipConfigurationAdapter: RecoverableApplyAdapter {
    public let id = "starship"
    public let version = "1"
    public let payloadVersion = "1"

    private let managedFiles: ManagedFiles
    private let locator: StarshipConfigurationLocator
    private let configuredConfigurationURL: URL?

    public init(
        managedFiles: ManagedFiles = ManagedFiles(),
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        xdgConfigHome: URL? = nil,
        configurationURL: URL? = nil
    ) {
        self.managedFiles = managedFiles
        self.locator = StarshipConfigurationLocator(homeDirectory: homeDirectory, xdgConfigHome: xdgConfigHome)
        self.configuredConfigurationURL = configurationURL?.standardizedFileURL
    }

    // MARK: Discovery

    public func discover() async throws -> StarshipDiscoveryReport {
        let candidates = try managedFiles.existingURLs(in: locator.candidates)
        let resolved = configuredConfigurationURL ?? candidates.last

        guard let resolved else {
            return StarshipDiscoveryReport(
                configurationCandidates: candidates,
                resolvedConfigurationURL: nil,
                configurationStatus: .missing
            )
        }

        let inspection: ManagedFileInspection
        do {
            inspection = try managedFiles.inspect(at: resolved)
        } catch {
            return StarshipDiscoveryReport(
                configurationCandidates: candidates,
                resolvedConfigurationURL: resolved,
                configurationStatus: .unsupported,
                detail: safeDiscoveryDetail(for: error)
            )
        }

        if case .managedByNix = inspection.ownership {
            return StarshipDiscoveryReport(
                configurationCandidates: candidates,
                resolvedConfigurationURL: resolved,
                configurationStatus: .unsupported,
                ownership: inspection.ownership,
                detail: "managed by Nix"
            )
        }

        if !inspection.snapshot.exists {
            return StarshipDiscoveryReport(
                configurationCandidates: candidates,
                resolvedConfigurationURL: resolved,
                configurationStatus: .missing,
                ownership: inspection.ownership,
                detail: "file not found"
            )
        }

        // Check for linked source (informational, not failure)
        // Validate TOML if file exists
        if let bytes = inspection.snapshot.bytes {
            do {
                try StarshipPaletteTransformer.validate(bytes)
            } catch let error as StarshipAdapterError {
                switch error {
                case .malformedConfiguration:
                    return StarshipDiscoveryReport(
                        configurationCandidates: candidates,
                        resolvedConfigurationURL: resolved,
                        configurationStatus: .malformed,
                        ownership: inspection.ownership,
                        detail: safeDiscoveryDetail(for: error)
                    )
                case .ambiguousConfiguration:
                    return StarshipDiscoveryReport(
                        configurationCandidates: candidates,
                        resolvedConfigurationURL: resolved,
                        configurationStatus: .ambiguous,
                        ownership: inspection.ownership,
                        detail: safeDiscoveryDetail(for: error)
                    )
                default:
                    return StarshipDiscoveryReport(
                        configurationCandidates: candidates,
                        resolvedConfigurationURL: resolved,
                        configurationStatus: .unsupported,
                        ownership: inspection.ownership,
                        detail: safeDiscoveryDetail(for: error)
                    )
                }
            } catch {
                return StarshipDiscoveryReport(
                    configurationCandidates: candidates,
                    resolvedConfigurationURL: resolved,
                    configurationStatus: .malformed,
                    ownership: inspection.ownership,
                    detail: safeDiscoveryDetail(for: error)
                )
            }
        }

        return StarshipDiscoveryReport(
            configurationCandidates: candidates,
            resolvedConfigurationURL: resolved,
            configurationStatus: .supported,
            ownership: inspection.ownership
        )
    }

    // MARK: Connection

    public func prepareConnection(instance: ConnectedTargetInstance, approveLinkedSource: Bool = false) async throws
        -> ConnectionPlan
    {
        let report = try await discover()
        // For Starship, we don't require installation validation; just file ownership
        let requestedURL = (configuredConfigurationURL ?? report.resolvedConfigurationURL ?? locator.defaultURL)
            .standardizedFileURL
        let inspection = try managedFiles.inspect(at: requestedURL)
        if case .managedByNix = inspection.ownership {
            throw StarshipAdapterError.managedByNix(inspection.resolvedURL)
        }
        // Validate existing content if any
        if let bytes = inspection.snapshot.bytes {
            do {
                try StarshipPaletteTransformer.validate(bytes)
            } catch let error as StarshipAdapterError {
                throw error
            }
        }

        let isLinked: URL? = {
            guard case .linkedUserOwned(let path) = inspection.ownership else { return nil }
            return URL(fileURLWithPath: path)
        }()

        let details = StarshipConnectionDetails(
            resolvedConfigURL: inspection.resolvedURL,
            resolvedConfigPermissions: inspection.snapshot.metadata?.permissions ?? 0o600,
            linkedSourceURL: isLinked,
            expectedReach: "next prompt"
        )

        // Connection baseline captures current inspection and any reviewed linked source; no file mutation yet.
        let baseline = StarshipConnectionBaseline(
            inspection: inspection,
            approvedLinkedSourceURL: approveLinkedSource ? isLinked : nil
        )
        let requiresApproval = isLinked != nil && !approveLinkedSource

        return ConnectionPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            capturedPreChangeState: try encode(baseline),
            intendedChangeDigest: digest(of: inspection.snapshot.bytes ?? Data()),
            staleStateToken: inspection.snapshot.staleStateToken,
            expectedSideEffects: [
                "Starship: configuration managed for theme palettes", "Starship: next prompt activation",
            ],
            requiredPermissions: ["Read the Starship configuration"],
            userActions: requiresApproval
                ? [
                    UserAction(
                        title: "Approve dotfiles source",
                        detail: "Oh My Theme will read \(isLinked?.path ?? "the linked source").")
                ] : [],
            opaquePayload: try encode(StarshipConnectionPayload(details: details, filePlan: nil)),
            requiresApproval: requiresApproval
        )
    }

    public func connect(_ plan: ConnectionPlan) async throws -> ConnectionReceipt {
        guard !plan.requiresApproval else {
            throw StarshipAdapterError.ambiguousConfiguration("linked source requires approval")
        }
        try await revalidateConnection(plan: plan)
        // No file mutation on connect for Starship; just mark connected
        return ConnectionReceipt(
            configurationState: .unchanged,
            runningInstanceReach: .newProcessesOnly,
            detail: "Starship connected; an applied theme will appear at the next prompt"
        )
    }

    public func revalidateConnection(plan: ConnectionPlan) async throws {
        let payload = try connectionPayload(from: plan)
        guard plan.adapterID == id, plan.adapterVersion == version else {
            throw StarshipAdapterError.malformedPlan
        }
        let current = try managedFiles.inspect(at: payload.details.resolvedConfigURL)
        guard current.snapshot.staleStateToken == plan.staleStateToken else {
            throw StarshipAdapterError.staleState
        }
    }

    public func classifyConnection(plan: ConnectionPlan) async throws -> ReconciliationClassification {
        let baseline = try decode(StarshipConnectionBaseline.self, from: plan.capturedPreChangeState)
        let payload = try connectionPayload(from: plan)
        let current = try managedFiles.inspect(at: payload.details.resolvedConfigURL)
        return current == baseline.inspection ? .beforeChange : .conflicting
    }

    public func restoreConnection(instance: ConnectedTargetInstance, baseline: Data) async throws -> ConnectionReceipt {
        let saved = try decode(StarshipConnectionBaseline.self, from: baseline)
        let current = try managedFiles.inspect(at: saved.inspection.requestedURL)
        let receipt = try restorationReceipt(from: current, to: saved.inspection)
        if receipt.changed {
            do {
                try managedFiles.rollback(receipt)
            } catch {
                throw StarshipAdapterError.restorationConflict
            }
        }
        return ConnectionReceipt(
            configurationState: receipt.changed ? .updated : .unchanged,
            runningInstanceReach: .nextPrompt,
            detail: receipt.changed
                ? "Starship restored its connection baseline; the next prompt will use it"
                : "Starship is already at its connection baseline"
        )
    }

    // MARK: Disconnect

    public func prepareDisconnect(
        instance: ConnectedTargetInstance, baseline: StoredConnectionBaseline, baselineData: Data
    ) async throws -> DisconnectPlan {
        let saved = try decode(StarshipConnectionBaseline.self, from: baselineData)
        let current = try managedFiles.inspect(at: saved.inspection.requestedURL)
        let restorationReceipt = try restorationReceipt(from: current, to: saved.inspection)
        let details = StarshipConnectionDetails(
            resolvedConfigURL: current.resolvedURL,
            resolvedConfigPermissions: current.snapshot.metadata?.permissions ?? 0o600,
            linkedSourceURL: linkedSourceURL(from: current.ownership),
            expectedReach: "next prompt"
        )
        return DisconnectPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            baselineReference: baseline.baselineReference,
            staleStateToken: current.snapshot.staleStateToken,
            opaquePayload: try encode(
                StarshipDisconnectPayload(details: details, restorationReceipt: restorationReceipt)
            )
        )
    }

    public func disconnect(_ plan: DisconnectPlan, baseline: Data) async throws -> AdapterReceipt {
        try await revalidateDisconnect(plan: plan)
        let saved = try decode(StarshipConnectionBaseline.self, from: baseline)
        let payload = try disconnectPayload(from: plan)
        guard payload.restorationReceipt.before == saved.inspection else {
            throw StarshipAdapterError.malformedPlan
        }
        if payload.restorationReceipt.changed {
            do {
                try managedFiles.rollback(payload.restorationReceipt)
            } catch {
                throw StarshipAdapterError.restorationConflict
            }
        }
        return AdapterReceipt(
            configurationState: payload.restorationReceipt.changed ? .updated : .unchanged,
            runningInstanceReach: .nextPrompt,
            detail: payload.restorationReceipt.changed
                ? "Starship disconnected and restored its baseline; the next prompt will use it"
                : "Starship disconnected without changing its configuration"
        )
    }

    public func revalidateDisconnect(plan: DisconnectPlan) async throws {
        let payload = try disconnectPayload(from: plan)
        let current = try managedFiles.inspect(at: payload.restorationReceipt.after.requestedURL)
        guard current == payload.restorationReceipt.after else {
            throw StarshipAdapterError.staleState
        }
    }

    public func classifyDisconnect(plan: DisconnectPlan) async throws -> ReconciliationClassification {
        let payload = try disconnectPayload(from: plan)
        let current = try managedFiles.inspect(at: payload.restorationReceipt.after.requestedURL)
        if current == payload.restorationReceipt.after {
            return .beforeChange
        }
        if current == payload.restorationReceipt.before {
            return .intendedAfterChange
        }
        return .conflicting
    }

    // MARK: Theme Apply

    public func prepareApply(instance: ConnectedTargetInstance, theme: PreparedTheme) async throws -> AdapterPlan {
        try await prepareApply(instance: instance, theme: theme, connectionBaseline: nil)
    }

    public func prepareApply(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme,
        connectionBaseline: Data?
    ) async throws -> AdapterPlan {
        let discoveredURL = try managedFiles.existingURLs(in: locator.candidates).last
        let requestedURL = (configuredConfigurationURL ?? discoveredURL ?? locator.defaultURL).standardizedFileURL
        let before = try managedFiles.inspect(at: requestedURL)
        if case .managedByNix = before.ownership {
            throw StarshipAdapterError.managedByNix(before.resolvedURL)
        }
        let linkedSource = linkedSourceURL(from: before.ownership)
        let linkedSourceApproved: Bool
        if let linkedSource {
            guard let connectionBaseline,
                let baseline = try? decode(StarshipConnectionBaseline.self, from: connectionBaseline),
                baseline.inspection.requestedURL == before.requestedURL,
                baseline.inspection.resolvedURL == before.resolvedURL,
                baseline.approvedLinkedSourceURL?.standardizedFileURL == linkedSource.standardizedFileURL
            else {
                throw StarshipAdapterError.linkedSourceApprovalRequired(linkedSource)
            }
            linkedSourceApproved = true
        } else {
            linkedSourceApproved = false
        }
        let existingBytes = before.snapshot.bytes ?? Data()
        // Reject malformed/ambiguous before preparing
        if before.snapshot.exists {
            do {
                try StarshipPaletteTransformer.validate(existingBytes)
            } catch let err as StarshipAdapterError {
                throw err
            }
        }
        let finalIntended = try StarshipPaletteTransformer.applyTheme(
            to: existingBytes,
            variant: theme.variant
        )

        let filePlan: ManagedFilePlan
        if before.snapshot.lineEnding == .none || before.snapshot.lineEnding == .mixed {
            // Allow creation from empty/missing or mixed line endings
            filePlan = try managedFiles.prepareForConnection(
                at: requestedURL,
                replacingWith: finalIntended,
                approveLinkedSource: linkedSourceApproved
            )
        } else {
            filePlan = try managedFiles.prepare(
                at: requestedURL,
                replacingWith: finalIntended,
                approveLinkedSource: linkedSourceApproved
            )
        }

        let details = StarshipConnectionDetails(
            resolvedConfigURL: before.resolvedURL,
            resolvedConfigPermissions: before.snapshot.metadata?.permissions ?? 0o600,
            linkedSourceURL: linkedSourceURL(from: before.ownership),
            expectedReach: "next prompt"
        )
        let state = StarshipThemeState(details: details, before: before, filePlan: filePlan)

        return AdapterPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            capabilityID: "theme",
            payload: AdapterPayloadEnvelope(
                adapterID: id, adapterVersion: version, payloadVersion: payloadVersion, payload: finalIntended),
            intendedChangeDigest: filePlan.intendedDigest,
            capturedPreChangeState: try encode(state),
            staleStateToken: before.snapshot.staleStateToken,
            expectedSideEffects: [
                "Starship: palette \(StarshipPaletteTransformer.ownedPaletteName) updated",
                "Starship: next prompt will reflect theme",
            ],
            requiredPermissions: ["Write the Starship configuration"],
            sourceType: theme.sourceType,
            sourceRevision: theme.sourceRevision,
            activationReach: .nextPrompt,
            setupNeeds: [],
            conflicts: []
        )
    }

    public func apply(_ plan: AdapterPlan) async throws -> AdapterReceipt {
        let state = try themeState(from: plan)
        guard plan.payload.payload == state.filePlan.intendedBytes else {
            throw StarshipAdapterError.malformedPlan
        }
        try await revalidateApply(plan: plan)
        // Validate intended bytes before writing
        do {
            try StarshipPaletteTransformer.validate(state.filePlan.intendedBytes)
        } catch let error as StarshipAdapterError {
            throw error
        } catch {
            throw StarshipAdapterError.malformedConfiguration(
                "the prepared Starship configuration is invalid"
            )
        }
        let receipt: ManagedFileReceipt
        do {
            receipt = try managedFiles.apply(state.filePlan, recoveryMarker: true)
        } catch {
            throw StarshipAdapterError.filesystemFailure(
                "the prepared Starship configuration could not be written safely"
            )
        }
        return AdapterReceipt(
            configurationState: receipt.changed ? .updated : .unchanged,
            runningInstanceReach: .nextPrompt,
            detail: receipt.changed
                ? "Starship theme updated; next prompt will use \(StarshipPaletteTransformer.ownedPaletteName) palette (existing prompt not redrawn)"
                : "Starship theme already selected; next prompt will use \(StarshipPaletteTransformer.ownedPaletteName) palette (existing prompt not redrawn)",
            rollbackData: try encode(receipt)
        )
    }

    public func revalidateApply(plan: AdapterPlan) async throws {
        let state = try themeState(from: plan)
        guard plan.adapterID == id,
            plan.adapterVersion == version,
            plan.payload.adapterID == id,
            plan.payload.adapterVersion == version,
            plan.payload.payloadVersion == payloadVersion,
            plan.payload.payload == state.filePlan.intendedBytes
        else {
            throw StarshipAdapterError.malformedPlan
        }
        let current = try managedFiles.inspect(at: state.before.requestedURL)
        guard current.resolvedURL == state.before.resolvedURL,
            current.snapshot.staleStateToken == state.before.snapshot.staleStateToken
        else {
            throw StarshipAdapterError.staleState
        }
    }

    public func recoverApplyReceipt(plan: AdapterPlan) async throws -> AdapterReceipt {
        let state = try themeState(from: plan)
        let current = try managedFiles.inspect(at: state.before.requestedURL)
        guard managedFiles.matchesMarkedApplication(current, of: state.filePlan) else {
            throw StarshipAdapterError.restorationConflict
        }
        let managedReceipt = ManagedFileReceipt(
            planID: state.filePlan.id,
            before: state.filePlan.inspection,
            after: current,
            changed: current != state.filePlan.inspection
        )
        return AdapterReceipt(
            configurationState: managedReceipt.changed ? .updated : .unchanged,
            runningInstanceReach: .nextPrompt,
            detail: "Starship theme apply recovered; the next prompt will use the selected palette",
            rollbackData: try encode(managedReceipt)
        )
    }

    public func classifyApply(plan: AdapterPlan) async throws -> ReconciliationClassification {
        let state = try themeState(from: plan)
        let current = try managedFiles.inspect(at: state.before.requestedURL)
        if current == state.before {
            return .beforeChange
        }
        if managedFiles.matchesMarkedApplication(current, of: state.filePlan) {
            return .intendedAfterChange
        }
        return .conflicting
    }

    public func rollbackApply(plan: AdapterPlan, receipt: AdapterReceipt) async throws {
        let state = try themeState(from: plan)
        let current = try managedFiles.inspect(at: state.before.requestedURL)
        guard current.snapshot.digest == state.filePlan.intendedDigest else {
            throw StarshipAdapterError.restorationConflict
        }
        guard let data = receipt.rollbackData,
            let managedReceipt = try? decode(ManagedFileReceipt.self, from: data),
            managedReceipt.planID == state.filePlan.id
        else {
            throw StarshipAdapterError.restorationConflict
        }
        do {
            try managedFiles.rollback(managedReceipt)
        } catch {
            throw StarshipAdapterError.filesystemFailure(
                "the Starship configuration no longer matches its apply receipt"
            )
        }
    }

    // MARK: - Helpers

    private func restorationReceipt(
        from current: ManagedFileInspection,
        to baseline: ManagedFileInspection
    ) throws -> ManagedFileReceipt {
        if current == baseline {
            return ManagedFileReceipt(planID: UUID(), before: baseline, after: current, changed: false)
        }
        guard managedFiles.matchesMarkedManagedState(current, preserving: baseline) else {
            throw StarshipAdapterError.restorationConflict
        }
        return ManagedFileReceipt(planID: UUID(), before: baseline, after: current, changed: true)
    }

    private func themeState(from plan: AdapterPlan) throws -> StarshipThemeState {
        guard let data = plan.capturedPreChangeState else { throw StarshipAdapterError.malformedPlan }
        return try decode(StarshipThemeState.self, from: data)
    }

    private func connectionPayload(from plan: ConnectionPlan) throws -> StarshipConnectionPayload {
        guard let data = plan.opaquePayload else { throw StarshipAdapterError.malformedPlan }
        return try decode(StarshipConnectionPayload.self, from: data)
    }

    private func disconnectPayload(from plan: DisconnectPlan) throws -> StarshipDisconnectPayload {
        guard let data = plan.opaquePayload else { throw StarshipAdapterError.malformedPlan }
        return try decode(StarshipDisconnectPayload.self, from: data)
    }

    private func safeDiscoveryDetail(for error: Error) -> String {
        switch error {
        case StarshipAdapterError.malformedConfiguration(let detail),
            StarshipAdapterError.ambiguousConfiguration(let detail):
            return detail
        case is ManagedFileError:
            return "The Starship configuration could not be inspected safely."
        default:
            return "The Starship configuration could not be read."
        }
    }

    private func linkedSourceURL(from ownership: ManagedFileOwnership) -> URL? {
        guard case .linkedUserOwned(let path) = ownership else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    private func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension ConnectionPlan {
    public var starshipDetails: StarshipConnectionDetails? {
        guard let opaquePayload,
            let payload = try? JSONDecoder().decode(StarshipConnectionPayload.self, from: opaquePayload)
        else { return nil }
        return payload.details
    }
}

extension DisconnectPlan {
    public var starshipDetails: StarshipConnectionDetails? {
        guard let opaquePayload,
            let payload = try? JSONDecoder().decode(StarshipDisconnectPayload.self, from: opaquePayload)
        else { return nil }
        return payload.details
    }
}
