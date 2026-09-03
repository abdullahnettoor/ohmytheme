import CryptoKit
import Foundation
import Persistence
import PlatformClients
import ThemeEngine
import ThemeModel

public enum VSCodeConnectionAdapterError: Error, Equatable, Sendable, CapabilityOutcomeError,
    ConnectionMutationNotStartedError
{
    case unsupportedInstance(TargetInstanceID)
    case installationUnavailable(VSCodeDiscoveryStatus, String?)
    case profileNameRequired
    case approvalRequired
    case companionVersionConflict(installed: String, pinned: String)
    case registrationUnavailable
    case setupInspectionFailed(String)
    case malformedPlan
    case staleState
    case restorationConflict

    public var capabilityConfigurationState: ConfigurationState {
        switch self {
        case .installationUnavailable, .registrationUnavailable:
            .unavailable
        case .staleState, .restorationConflict:
            .conflicted
        case .unsupportedInstance, .profileNameRequired, .approvalRequired,
            .companionVersionConflict, .setupInspectionFailed, .malformedPlan:
            .failed
        }
    }

    public var capabilityActivationReach: ActivationReach { .unavailable }

    public var capabilityOutcomeDetail: String {
        switch self {
        case .unsupportedInstance(let id):
            "Unsupported VS Code Target Instance: \(id.rawValue)."
        case .installationUnavailable(let status, let detail):
            detail ?? "VS Code application discovery returned \(status.rawValue)."
        case .profileNameRequired:
            "Choose the VS Code profile to connect."
        case .approvalRequired:
            "Approve installation of the pinned VS Code companion before connecting."
        case .companionVersionConflict(let installed, let pinned):
            "Companion version \(installed) is installed; Oh My Theme will not replace it with pinned version \(pinned) without a separately restorable baseline."
        case .registrationUnavailable:
            "The pinned companion did not register the expected VS Code profile or window."
        case .setupInspectionFailed(let detail):
            "VS Code setup could not be inspected before installation: \(detail)"
        case .malformedPlan:
            "The VS Code connection plan is malformed or incompatible."
        case .staleState:
            "VS Code setup changed after the connection preview was prepared."
        case .restorationConflict:
            "VS Code companion setup changed outside Oh My Theme; restoration was refused."
        }
    }
}

public struct VSCodeSetupRecoveryRequired: MutationRecoveryRequiredError, Equatable, Sendable {
    public let targetInstanceID: TargetInstanceID

    public init(targetInstanceID: TargetInstanceID) {
        self.targetInstanceID = targetInstanceID
    }

    public var capabilityConfigurationState: ConfigurationState { .failed }
    public var capabilityActivationReach: ActivationReach { .unavailable }
    public var capabilityOutcomeDetail: String {
        "The pinned companion was installed, but the expected VS Code profile/window has not registered yet. Setup will be reconciled before another operation."
    }
}

public struct VSCodeConnectionBaseline: Codable, Equatable, Sendable {
    public let installation: VSCodeInstallation
    public let profileName: String
    public let extensionID: String
    public let installedCompanion: VSCodeCompanionInstallation?
    public let installationOwnershipToken: String

    public init(
        installation: VSCodeInstallation,
        profileName: String,
        extensionID: String,
        installedCompanion: VSCodeCompanionInstallation?,
        installationOwnershipToken: String
    ) {
        self.installation = installation
        self.profileName = profileName
        self.extensionID = extensionID
        self.installedCompanion = installedCompanion
        self.installationOwnershipToken = installationOwnershipToken
    }
}

public struct VSCodeConnectionPayload: Codable, Equatable, Sendable {
    public let installation: VSCodeInstallation
    public let artifact: VSCodeCompanionArtifact
    public let expectation: VSCodeRegistrationExpectation
    public let requestedScope: CompanionApplyTarget
    public let socketBehavior: String

    public init(
        installation: VSCodeInstallation,
        artifact: VSCodeCompanionArtifact,
        expectation: VSCodeRegistrationExpectation,
        requestedScope: CompanionApplyTarget,
        socketBehavior: String
    ) {
        self.installation = installation
        self.artifact = artifact
        self.expectation = expectation
        self.requestedScope = requestedScope
        self.socketBehavior = socketBehavior
    }
}

public struct VSCodeDisconnectPayload: Codable, Equatable, Sendable {
    public let before: VSCodeCompanionInstallation?
    public let baseline: VSCodeCompanionInstallation?
    public let ownershipToken: String
    public let connection: VSCodeConnectionPayload

    public init(
        before: VSCodeCompanionInstallation?,
        baseline: VSCodeCompanionInstallation?,
        ownershipToken: String,
        connection: VSCodeConnectionPayload
    ) {
        self.before = before
        self.baseline = baseline
        self.ownershipToken = ownershipToken
        self.connection = connection
    }
}

/// Owns approval, pinned companion installation, authenticated registration
/// matching, and safe setup recovery for one VS Code profile/window Target Instance.
/// Theme apply is intentionally left to issue #20.
public actor VSCodeConnectionAdapter: RecoverableConnectionAdapter {
    public let id = "vscode"
    public let version = "1.0.0"

    public static let socketBehavior =
        "The companion connects outward to an app-owned per-user Unix-domain socket using a per-launch nonce; no TCP listener or custom URI carries theme changes."

    private let platform: any VSCodeConnectionPlatform
    private let artifact: VSCodeCompanionArtifact
    private let selectedBundleURL: URL
    private let selectedProfileName: String
    private let expectedRegistration: VSCodeRegistrationExpectation

    public init(
        platform: any VSCodeConnectionPlatform,
        artifact: VSCodeCompanionArtifact,
        selectedBundleURL: URL,
        selectedProfileName: String,
        expectedRegistration: VSCodeRegistrationExpectation
    ) {
        self.platform = platform
        self.artifact = artifact
        self.selectedBundleURL = selectedBundleURL.standardizedFileURL
        self.selectedProfileName = selectedProfileName
        self.expectedRegistration = expectedRegistration
    }

    public static func targetInstanceID(
        for expectation: VSCodeRegistrationExpectation
    ) -> TargetInstanceID {
        let profile = expectation.profileID ?? expectation.profileName ?? "unknown-profile"
        switch expectation.scope {
        case .profile:
            return TargetInstanceID(
                rawValue: "vscode:\(expectation.edition.rawValue):profile:\(profile)"
            )
        case .window:
            let process = expectation.windowID ?? expectation.processID.map(String.init) ?? "unknown-window"
            return TargetInstanceID(
                rawValue: "vscode:\(expectation.edition.rawValue):window:\(profile):\(process)"
            )
        }
    }

    // MARK: - Connection

    public func prepareConnection(
        instance: ConnectedTargetInstance,
        approveLinkedSource: Bool = false
    ) async throws -> ConnectionPlan {
        try validate(instance)
        guard !selectedProfileName.isEmpty else {
            throw VSCodeConnectionAdapterError.profileNameRequired
        }
        let profileName = selectedProfileName
        let discovery = try await platform.discover(selectedBundleURL: selectedBundleURL)
        guard discovery.status == .supported,
            let installation = discovery.selectedInstallation
        else {
            throw VSCodeConnectionAdapterError.installationUnavailable(
                discovery.status,
                discovery.detail
            )
        }
        guard installation.edition == expectedRegistration.edition,
            installation.version == expectedRegistration.applicationVersion
        else {
            throw VSCodeConnectionAdapterError.installationUnavailable(
                .unsupported,
                "The selected application no longer matches the expected edition and version."
            )
        }

        let installed = try await platform.installedCompanion(
            using: installation,
            profileName: profileName,
            extensionID: artifact.extensionID
        )
        if let installed, installed.version != artifact.version {
            throw VSCodeConnectionAdapterError.companionVersionConflict(
                installed: installed.version,
                pinned: artifact.version
            )
        }
        let baseline = VSCodeConnectionBaseline(
            installation: installation,
            profileName: profileName,
            extensionID: artifact.extensionID,
            installedCompanion: installed,
            installationOwnershipToken: UUID().uuidString
        )
        let payload = VSCodeConnectionPayload(
            installation: installation,
            artifact: artifact,
            expectation: expectedRegistration,
            requestedScope: .global,
            socketBehavior: Self.socketBehavior
        )
        let needsInstallation = installed == nil
        let approved = !needsInstallation || approveLinkedSource
        let baselineData = try encode(baseline)

        return ConnectionPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            capturedPreChangeState: baselineData,
            intendedChangeDigest: digest(of: try encode(payload)),
            staleStateToken: stateToken(installed),
            expectedSideEffects: [
                "Install pinned companion \(artifact.extensionID)@\(artifact.version) through \(installation.executableURL.path).",
                Self.socketBehavior,
                "Request global workbench.colorTheme scope for profile \(profileName).",
                identityDescription(expectedRegistration),
            ],
            requiredPermissions: [
                "Run the documented VS Code executable inside the selected application bundle."
            ],
            userActions: needsInstallation && !approved
                ? [
                    UserAction(
                        title: "Approve VS Code companion installation",
                        detail:
                            "Install \(artifact.extensionID)@\(artifact.version) for profile \(profileName) using \(installation.executableURL.path)."
                    )
                ] : [],
            opaquePayload: try encode(payload),
            requiresApproval: !approved
        )
    }

    public func connect(_ plan: ConnectionPlan) async throws -> ConnectionReceipt {
        guard !plan.requiresApproval else {
            throw VSCodeConnectionAdapterError.approvalRequired
        }
        try await revalidateConnection(plan: plan)
        let payload = try connectionPayload(from: plan)
        let baseline: VSCodeConnectionBaseline = try decode(plan.capturedPreChangeState)
        let current = baseline.installedCompanion
        let changed: Bool
        if current == nil {
            do {
                try await platform.install(
                    payload.artifact,
                    ownershipToken: baseline.installationOwnershipToken,
                    using: payload.installation,
                    profileName: baseline.profileName
                )
            } catch {
                throw VSCodeSetupRecoveryRequired(targetInstanceID: plan.targetInstanceID)
            }
            changed = true
        } else {
            changed = false
        }

        guard let registration = await platform.registration(matching: payload.expectation) else {
            if changed {
                throw VSCodeSetupRecoveryRequired(targetInstanceID: plan.targetInstanceID)
            }
            throw VSCodeConnectionAdapterError.registrationUnavailable
        }
        return ConnectionReceipt(
            configurationState: changed ? .updated : .unchanged,
            runningInstanceReach: .currentInstances,
            detail:
                "Connected \(payload.installation.edition.displayName) \(payload.installation.version), profile \(displayProfile(registration.vscode)), process/window \(displayProcess(registration.vscode)); companion \(registration.extensionVersion) registered for global color-theme changes."
        )
    }

    public func revalidateConnection(plan: ConnectionPlan) async throws {
        try validate(plan)
        let baseline: VSCodeConnectionBaseline = try decode(plan.capturedPreChangeState)
        let discovery: VSCodeDiscoveryReport
        let current: VSCodeCompanionInstallation?
        do {
            discovery = try await platform.discover(selectedBundleURL: selectedBundleURL)
            current = try await installedCompanion(for: baseline)
        } catch {
            throw VSCodeConnectionAdapterError.setupInspectionFailed(String(describing: error))
        }
        guard discovery.status == .supported,
            discovery.selectedInstallation == baseline.installation
        else {
            throw WriteBoundaryConflict(
                targetInstanceID: plan.targetInstanceID,
                detail: "The selected VS Code application changed after connection was prepared."
            )
        }
        guard current == baseline.installedCompanion else {
            throw WriteBoundaryConflict(
                targetInstanceID: plan.targetInstanceID,
                detail: "The installed VS Code companion changed after connection was prepared."
            )
        }
    }

    public func classifyConnection(
        plan: ConnectionPlan
    ) async throws -> ReconciliationClassification {
        guard isCurrent(plan) else { throw VSCodeConnectionAdapterError.malformedPlan }
        let baseline: VSCodeConnectionBaseline = try decode(plan.capturedPreChangeState)
        let payload = try connectionPayload(from: plan)
        let current = try await installedCompanion(for: baseline)
        if current == baseline.installedCompanion {
            guard current != nil else { return .beforeChange }
            return await platform.registration(matching: payload.expectation) == nil
                ? .beforeChange : .intendedAfterChange
        }
        if baseline.installedCompanion == nil,
            current == ownedInstallation(for: baseline)
        {
            // Registration reconnects through the new launch rendezvous. Do not
            // call setup complete until the intended profile/window has proved
            // its identity again.
            guard await platform.registration(matching: payload.expectation) != nil else {
                return .conflicting
            }
            return .intendedAfterChange
        }
        return .conflicting
    }

    public func recoverConnectionReceipt(plan: ConnectionPlan) async throws -> ConnectionReceipt {
        try validate(plan)
        let baseline: VSCodeConnectionBaseline = try decode(plan.capturedPreChangeState)
        let payload = try connectionPayload(from: plan)
        let current = try await installedCompanion(for: baseline)
        let configurationState: ConfigurationState
        if current == baseline.installedCompanion {
            configurationState = .unchanged
        } else if baseline.installedCompanion == nil,
            current == ownedInstallation(for: baseline)
        {
            configurationState = .updated
        } else {
            throw VSCodeConnectionAdapterError.restorationConflict
        }
        guard let registration = await platform.registration(matching: payload.expectation)
        else {
            throw VSCodeSetupRecoveryRequired(targetInstanceID: plan.targetInstanceID)
        }
        return ConnectionReceipt(
            configurationState: configurationState,
            runningInstanceReach: .currentInstances,
            detail:
                "Recovered the VS Code companion connection for profile \(displayProfile(registration.vscode)) and process/window \(displayProcess(registration.vscode))."
        )
    }

    public func restoreConnection(
        instance: ConnectedTargetInstance,
        baseline: Data
    ) async throws -> ConnectionReceipt {
        try validate(instance)
        let saved: VSCodeConnectionBaseline = try decode(baseline)
        let current = try await installedCompanion(for: saved)
        let changed = try await restore(current: current, to: saved)
        return ConnectionReceipt(
            configurationState: changed ? .updated : .unchanged,
            runningInstanceReach: .currentInstances,
            detail: changed
                ? "Removed the pinned VS Code companion installed during connection and restored the Connection Baseline."
                : "VS Code companion setup already matches its Connection Baseline."
        )
    }

    // MARK: - Disconnect

    public func prepareDisconnect(
        instance: ConnectedTargetInstance,
        baseline: StoredConnectionBaseline,
        baselineData: Data
    ) async throws -> DisconnectPlan {
        try validate(instance)
        guard baseline.adapterID == id, baseline.adapterVersion == version else {
            throw VSCodeConnectionAdapterError.malformedPlan
        }
        let saved: VSCodeConnectionBaseline = try decode(baselineData)
        let current = try await installedCompanion(for: saved)
        try validateRestorable(current: current, baseline: saved)
        let payload = VSCodeConnectionPayload(
            installation: saved.installation,
            artifact: artifact,
            expectation: expectedRegistration,
            requestedScope: .global,
            socketBehavior: Self.socketBehavior
        )
        return DisconnectPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            baselineReference: baseline.baselineReference,
            staleStateToken: stateToken(current),
            opaquePayload: try encode(
                VSCodeDisconnectPayload(
                    before: current,
                    baseline: saved.installedCompanion,
                    ownershipToken: saved.installationOwnershipToken,
                    connection: payload
                )
            )
        )
    }

    public func disconnect(
        _ plan: DisconnectPlan,
        baseline: Data
    ) async throws -> AdapterReceipt {
        try await revalidateDisconnect(plan: plan)
        let saved: VSCodeConnectionBaseline = try decode(baseline)
        let current = try await installedCompanion(for: saved)
        let changed = try await restore(current: current, to: saved)
        return AdapterReceipt(
            configurationState: changed ? .updated : .unchanged,
            runningInstanceReach: .currentInstances,
            detail: changed
                ? "Disconnected VS Code and removed the companion installed by Oh My Theme."
                : "Disconnected VS Code without changing its pre-existing companion setup."
        )
    }

    public func revalidateDisconnect(plan: DisconnectPlan) async throws {
        guard plan.adapterID == id,
            plan.adapterVersion == version,
            plan.targetInstanceID == Self.targetInstanceID(for: expectedRegistration),
            let data = plan.opaquePayload
        else {
            throw VSCodeConnectionAdapterError.malformedPlan
        }
        let payload: VSCodeDisconnectPayload = try decode(data)
        let baseline = VSCodeConnectionBaseline(
            installation: payload.connection.installation,
            profileName: selectedProfileName,
            extensionID: payload.connection.artifact.extensionID,
            installedCompanion: payload.baseline,
            installationOwnershipToken: payload.ownershipToken
        )
        let current = try await installedCompanion(for: baseline)
        guard current == payload.before,
            plan.staleStateToken == stateToken(current)
        else {
            throw WriteBoundaryConflict(
                targetInstanceID: plan.targetInstanceID,
                detail: "VS Code companion setup changed after disconnect was prepared."
            )
        }
    }

    public func classifyDisconnect(
        plan: DisconnectPlan
    ) async throws -> ReconciliationClassification {
        guard plan.adapterID == id,
            plan.adapterVersion == version,
            let data = plan.opaquePayload
        else {
            throw VSCodeConnectionAdapterError.malformedPlan
        }
        let payload: VSCodeDisconnectPayload = try decode(data)
        let saved = VSCodeConnectionBaseline(
            installation: payload.connection.installation,
            profileName: selectedProfileName,
            extensionID: payload.connection.artifact.extensionID,
            installedCompanion: payload.baseline,
            installationOwnershipToken: payload.ownershipToken
        )
        let current = try await installedCompanion(for: saved)
        if current == payload.before { return .beforeChange }
        if current == payload.baseline { return .intendedAfterChange }
        return .conflicting
    }

    // MARK: - Helpers

    private func validate(_ instance: ConnectedTargetInstance) throws {
        guard instance.adapterID == id,
            instance.id == Self.targetInstanceID(for: expectedRegistration)
        else {
            throw VSCodeConnectionAdapterError.unsupportedInstance(instance.id)
        }
    }

    private func validate(_ plan: ConnectionPlan) throws {
        guard isCurrent(plan) else { throw VSCodeConnectionAdapterError.malformedPlan }
        _ = try connectionPayload(from: plan)
    }

    private func isCurrent(_ plan: ConnectionPlan) -> Bool {
        plan.adapterID == id
            && plan.adapterVersion == version
            && plan.targetInstanceID == Self.targetInstanceID(for: expectedRegistration)
    }

    private func connectionPayload(from plan: ConnectionPlan) throws -> VSCodeConnectionPayload {
        guard isCurrent(plan), let opaquePayload = plan.opaquePayload else {
            throw VSCodeConnectionAdapterError.malformedPlan
        }
        let payload: VSCodeConnectionPayload = try decode(opaquePayload)
        guard payload.artifact == artifact,
            payload.installation.bundleURL == selectedBundleURL,
            payload.expectation == expectedRegistration,
            payload.requestedScope == .global
        else {
            throw VSCodeConnectionAdapterError.malformedPlan
        }
        return payload
    }

    private func installedCompanion(
        for baseline: VSCodeConnectionBaseline
    ) async throws -> VSCodeCompanionInstallation? {
        try await platform.installedCompanion(
            using: baseline.installation,
            profileName: baseline.profileName,
            extensionID: baseline.extensionID
        )
    }

    private func validateRestorable(
        current: VSCodeCompanionInstallation?,
        baseline: VSCodeConnectionBaseline
    ) throws {
        if current == baseline.installedCompanion { return }
        guard baseline.installedCompanion == nil,
            current
                == VSCodeCompanionInstallation(
                    extensionID: artifact.extensionID,
                    version: artifact.version,
                    ownershipToken: baseline.installationOwnershipToken
                )
        else {
            throw VSCodeConnectionAdapterError.restorationConflict
        }
    }

    private func restore(
        current: VSCodeCompanionInstallation?,
        to baseline: VSCodeConnectionBaseline
    ) async throws -> Bool {
        try validateRestorable(current: current, baseline: baseline)
        guard baseline.installedCompanion == nil, current != nil else { return false }
        try await platform.uninstall(
            extensionID: baseline.extensionID,
            version: artifact.version,
            ownershipToken: baseline.installationOwnershipToken,
            using: baseline.installation,
            profileName: baseline.profileName
        )
        return true
    }

    private func ownedInstallation(
        for baseline: VSCodeConnectionBaseline
    ) -> VSCodeCompanionInstallation {
        VSCodeCompanionInstallation(
            extensionID: artifact.extensionID,
            version: artifact.version,
            ownershipToken: baseline.installationOwnershipToken
        )
    }

    private func stateToken(_ installation: VSCodeCompanionInstallation?) -> String {
        guard let installation else { return "absent" }
        return
            "\(installation.extensionID.lowercased())@\(installation.version)#\(installation.ownershipToken ?? "unowned")"
    }

    private func identityDescription(_ expectation: VSCodeRegistrationExpectation) -> String {
        let profile = expectation.profileName ?? expectation.profileID ?? "selected profile"
        let process = expectation.windowID ?? expectation.processID.map(String.init) ?? "selected process/window"
        return
            "Accept only \(expectation.edition.displayName) \(expectation.applicationVersion), profile \(profile), process/window \(process)."
    }

    private func displayProfile(_ identity: CompanionVSCodeIdentity) -> String {
        if !identity.profileName.isEmpty { return identity.profileName }
        if !identity.profileId.isEmpty { return identity.profileId }
        return "selected profile"
    }

    private func displayProcess(_ identity: CompanionVSCodeIdentity) -> String {
        if !identity.windowId.isEmpty { return identity.windowId }
        if !identity.sessionId.isEmpty { return identity.sessionId }
        return String(identity.processId)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw VSCodeConnectionAdapterError.malformedPlan
        }
    }

    private func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
