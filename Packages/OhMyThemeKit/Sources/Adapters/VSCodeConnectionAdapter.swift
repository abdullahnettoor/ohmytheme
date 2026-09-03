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

public enum VSCodeThemeAdapterError: Error, Equatable, Sendable, CapabilityOutcomeError {
    case notConnected
    case malformedThemeArtifact
    case malformedPlan
    case requestFailed(VSCodeCompanionRequestError)
    case unsupportedTheme(String)
    case updateFailed(code: String, message: String)
    case externalSettingChanged

    public var capabilityConfigurationState: ConfigurationState {
        switch self {
        case .externalSettingChanged, .requestFailed(.staleRequest):
            .conflicted
        case .notConnected, .unsupportedTheme:
            .unavailable
        case .malformedThemeArtifact, .malformedPlan, .requestFailed, .updateFailed:
            .failed
        }
    }

    public var capabilityActivationReach: ActivationReach { .unavailable }

    public var capabilityOutcomeDetail: String {
        switch self {
        case .notConnected:
            "The intended VS Code Target Instance is not connected."
        case .malformedThemeArtifact:
            "The prepared VS Code theme identity is missing or malformed."
        case .malformedPlan:
            "The VS Code theme plan or receipt is malformed or incompatible."
        case .requestFailed(let error):
            switch error {
            case .timeout:
                "The VS Code companion request timed out. The setting will be inspected before another mutation."
            case .disconnected, .targetUnavailable, .notRunning:
                "The intended VS Code companion disconnected before acknowledging the request."
            case .staleRequest:
                "VS Code rejected a stale theme request because its configured theme changed."
            case .duplicateRequest:
                "VS Code rejected a duplicate companion request identifier."
            case .unsupportedProtocol:
                "The VS Code companion rejected the request protocol version."
            case .malformedAcknowledgement:
                "The VS Code companion returned a malformed or mismatched acknowledgement."
            }
        case .unsupportedTheme(let name):
            "VS Code does not have the requested theme installed: \(name)."
        case .updateFailed(let code, let message):
            "VS Code could not update its theme (\(code)): \(message)"
        case .externalSettingChanged:
            "VS Code's configured theme changed outside Oh My Theme; the update was refused."
        }
    }
}

public struct VSCodeTokenColor: Codable, Equatable, Sendable {
    public let scopes: [String]
    public let foreground: String

    public init(scopes: [String], foreground: String) {
        self.scopes = scopes
        self.foreground = foreground
    }
}

public struct VSCodeThemeArtifact: Codable, Equatable, Sendable {
    public let themeName: String
    public let uiTheme: String?
    public let colors: [String: String]
    public let tokenColors: [VSCodeTokenColor]

    public init(
        themeName: String,
        uiTheme: String? = nil,
        colors: [String: String] = [:],
        tokenColors: [VSCodeTokenColor] = []
    ) {
        self.themeName = themeName
        self.uiTheme = uiTheme
        self.colors = colors
        self.tokenColors = tokenColors
    }

    private enum CodingKeys: String, CodingKey {
        case themeName
        case uiTheme
        case colors
        case tokenColors
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            themeName: try container.decode(String.self, forKey: .themeName),
            uiTheme: try container.decodeIfPresent(String.self, forKey: .uiTheme),
            colors: try container.decodeIfPresent([String: String].self, forKey: .colors) ?? [:],
            tokenColors: try container.decodeIfPresent([VSCodeTokenColor].self, forKey: .tokenColors) ?? []
        )
    }
}

public struct VSCodeThemeIdentity: Codable, Equatable, Sendable {
    public let variantID: String
    public let displayName: String
    public let sourceType: ThemeSourceKind
    public let sourceRevision: String
    public let contentDigest: String

    public init(
        variantID: String,
        displayName: String,
        sourceType: ThemeSourceKind,
        sourceRevision: String,
        contentDigest: String
    ) {
        self.variantID = variantID
        self.displayName = displayName
        self.sourceType = sourceType
        self.sourceRevision = sourceRevision
        self.contentDigest = contentDigest
    }
}

public struct VSCodeThemePlanPayload: Codable, Equatable, Sendable {
    public let theme: VSCodeThemeIdentity
    public let artifact: VSCodeThemeArtifact
    public let request: VSCodeCompanionThemeRequest
    public let expectation: VSCodeRegistrationExpectation
    public let serverSessionID: String

    public init(
        theme: VSCodeThemeIdentity,
        artifact: VSCodeThemeArtifact,
        request: VSCodeCompanionThemeRequest,
        expectation: VSCodeRegistrationExpectation,
        serverSessionID: String
    ) {
        self.theme = theme
        self.artifact = artifact
        self.request = request
        self.expectation = expectation
        self.serverSessionID = serverSessionID
    }
}

public struct VSCodeThemeReceipt: Codable, Equatable, Sendable {
    public let request: VSCodeCompanionThemeRequest
    public let acknowledgement: CompanionApplyThemeAckMessage?
    public let recoveryInspection: CompanionThemeInspection?

    public init(
        request: VSCodeCompanionThemeRequest,
        acknowledgement: CompanionApplyThemeAckMessage?,
        recoveryInspection: CompanionThemeInspection? = nil
    ) {
        self.request = request
        self.acknowledgement = acknowledgement
        self.recoveryInspection = recoveryInspection
    }
}

public struct VSCodeRollbackNotStarted: RollbackMutationNotStartedError, CapabilityOutcomeError,
    Equatable, Sendable
{
    public let cause: VSCodeThemeAdapterError

    public init(cause: VSCodeThemeAdapterError) {
        self.cause = cause
    }

    public var capabilityConfigurationState: ConfigurationState {
        cause.capabilityConfigurationState
    }
    public var capabilityActivationReach: ActivationReach {
        cause.capabilityActivationReach
    }
    public var capabilityOutcomeDetail: String {
        cause.capabilityOutcomeDetail
    }
}

public struct VSCodeThemeRecoveryRequired: MutationRecoveryRequiredError, Equatable, Sendable {
    public let targetInstanceID: TargetInstanceID
    public let requestError: VSCodeCompanionRequestError

    public init(
        targetInstanceID: TargetInstanceID,
        requestError: VSCodeCompanionRequestError
    ) {
        self.targetInstanceID = targetInstanceID
        self.requestError = requestError
    }

    public var capabilityConfigurationState: ConfigurationState { .failed }
    public var capabilityActivationReach: ActivationReach { .unavailable }
    public var capabilityOutcomeDetail: String {
        "The VS Code companion request ended without a trustworthy acknowledgement. The configured theme must be reconciled before another mutation."
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

/// Owns setup, authenticated registration matching, guarded theme updates,
/// acknowledgement receipts, recovery, and Undo for one VS Code Target Instance.
public actor VSCodeConnectionAdapter: RecoverableConnectionAdapter, RecoverableApplyAdapter,
    RecoverableRollbackAdapter
{
    public let id = "vscode"
    public let version = "1.0.0"
    public let payloadVersion = "1"

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

    // MARK: - Theme apply

    public func prepareApply(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme
    ) async throws -> AdapterPlan {
        try await prepareApply(instance: instance, theme: theme, connectionBaseline: nil)
    }

    public func prepareApply(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme,
        connectionBaseline: Data?
    ) async throws -> AdapterPlan {
        try validate(instance)
        guard let connectionBaseline,
            let baseline = try? JSONDecoder().decode(
                VSCodeConnectionBaseline.self,
                from: connectionBaseline
            ),
            baseline.installation.bundleURL == selectedBundleURL,
            baseline.profileName == selectedProfileName,
            baseline.extensionID == artifact.extensionID
        else {
            throw VSCodeThemeAdapterError.notConnected
        }
        guard let registration = await platform.registration(matching: expectedRegistration) else {
            throw VSCodeThemeAdapterError.notConnected
        }
        let inspection: CompanionThemeInspection
        do {
            inspection = try await platform.inspectTheme(
                serverSessionID: registration.serverSessionID,
                matching: expectedRegistration
            )
        } catch let error as VSCodeCompanionRequestError {
            throw VSCodeThemeAdapterError.requestFailed(error)
        }
        let themeArtifact: VSCodeThemeArtifact
        if let upstreamArtifact = theme.upstreamArtifact {
            guard let pinned = try? JSONDecoder().decode(
                VSCodeThemeArtifact.self,
                from: upstreamArtifact
            ), !pinned.themeName.isEmpty else {
                throw VSCodeThemeAdapterError.malformedThemeArtifact
            }
            themeArtifact = pinned
        } else {
            themeArtifact = try compileGeneratedTheme(theme)
        }
        let themeName = themeArtifact.themeName
        let identity = VSCodeThemeIdentity(
            variantID: theme.variantID,
            displayName: themeName,
            sourceType: theme.sourceType,
            sourceRevision: theme.sourceRevision,
            contentDigest: theme.contentDigest
        )
        let request = VSCodeCompanionThemeRequest(
            protocolVersion: CompanionProtocol.currentVersion,
            themeName: themeName,
            expectedSetting: inspection.configuredSetting,
            target: .global
        )
        let payload = VSCodeThemePlanPayload(
            theme: identity,
            artifact: themeArtifact,
            request: request,
            expectation: expectedRegistration,
            serverSessionID: registration.serverSessionID
        )
        let payloadData = try encode(payload)
        return AdapterPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            capabilityID: "colorTheme",
            payload: AdapterPayloadEnvelope(
                adapterID: id,
                adapterVersion: version,
                payloadVersion: payloadVersion,
                payload: payloadData
            ),
            intendedChangeDigest: digest(of: payloadData),
            capturedPreChangeState: try encode(inspection),
            staleStateToken: digest(of: try encode(inspection)),
            expectedSideEffects: [
                "Update workbench.colorTheme in the selected VS Code profile through the pinned companion.",
                identityDescription(expectedRegistration),
            ],
            sourceType: theme.sourceType,
            sourceRevision: theme.sourceRevision,
            activationReach: .currentInstances
        )
    }

    public func revalidateApply(plan: AdapterPlan) async throws {
        let payload = try themePayload(from: plan)
        let current: CompanionThemeInspection
        do {
            current = try await platform.inspectTheme(
                serverSessionID: payload.serverSessionID,
                matching: payload.expectation
            )
        } catch let error as VSCodeCompanionRequestError {
            throw VSCodeThemeAdapterError.requestFailed(error)
        }
        guard current.configuredSetting == payload.request.expectedSetting else {
            throw WriteBoundaryConflict(
                targetInstanceID: plan.targetInstanceID,
                detail: "VS Code's configured theme changed after the preview was prepared."
            )
        }
    }

    public func apply(_ plan: AdapterPlan) async throws -> AdapterReceipt {
        try await revalidateApply(plan: plan)
        let payload = try themePayload(from: plan)
        let outcome: CompanionApplyOutcome
        do {
            outcome = try await platform.applyTheme(
                payload.request,
                serverSessionID: payload.serverSessionID,
                matching: payload.expectation
            )
        } catch let error as VSCodeCompanionRequestError {
            switch error {
            case .timeout, .disconnected, .duplicateRequest, .malformedAcknowledgement,
                .targetUnavailable, .notRunning:
                throw VSCodeThemeRecoveryRequired(
                    targetInstanceID: plan.targetInstanceID,
                    requestError: error
                )
            case .staleRequest, .unsupportedProtocol:
                throw VSCodeThemeAdapterError.requestFailed(error)
            }
        }
        guard outcome.sessionID == payload.serverSessionID else {
            throw VSCodeThemeRecoveryRequired(
                targetInstanceID: plan.targetInstanceID,
                requestError: .malformedAcknowledgement
            )
        }
        do {
            return try receipt(
                for: payload.request,
                acknowledgement: outcome.acknowledgement
            )
        } catch VSCodeThemeAdapterError.requestFailed(.malformedAcknowledgement) {
            throw VSCodeThemeRecoveryRequired(
                targetInstanceID: plan.targetInstanceID,
                requestError: .malformedAcknowledgement
            )
        } catch VSCodeThemeAdapterError.updateFailed {
            // VS Code may throw or fail verification after changing the setting.
            // Inspection must classify the external state before this operation ends.
            throw VSCodeThemeRecoveryRequired(
                targetInstanceID: plan.targetInstanceID,
                requestError: .malformedAcknowledgement
            )
        }
    }

    public func classifyApply(plan: AdapterPlan) async throws -> ReconciliationClassification {
        let payload = try themePayload(from: plan)
        let before = try decodeInspection(plan.capturedPreChangeState)
        let recoverySessionID = try await registeredSessionID(for: payload.expectation)
        let current: CompanionThemeInspection
        do {
            current = try await platform.inspectTheme(
                serverSessionID: recoverySessionID,
                matching: payload.expectation
            )
        } catch let error as VSCodeCompanionRequestError {
            throw VSCodeThemeAdapterError.requestFailed(error)
        }
        if current.configuredSetting == payload.request.themeName {
            return .intendedAfterChange
        }
        if current.configuredSetting == before.configuredSetting {
            return .beforeChange
        }
        return .conflicting
    }

    public func recoverApplyReceipt(plan: AdapterPlan) async throws -> AdapterReceipt {
        let payload = try themePayload(from: plan)
        let before = try decodeInspection(plan.capturedPreChangeState)
        let recoverySessionID = try await registeredSessionID(for: payload.expectation)
        let current: CompanionThemeInspection
        do {
            current = try await platform.inspectTheme(
                serverSessionID: recoverySessionID,
                matching: payload.expectation
            )
        } catch let error as VSCodeCompanionRequestError {
            throw VSCodeThemeAdapterError.requestFailed(error)
        }
        guard current.configuredSetting == payload.request.themeName else {
            throw VSCodeThemeAdapterError.externalSettingChanged
        }
        return AdapterReceipt(
            configurationState: before.configuredSetting == current.configuredSetting
                ? .unchanged : .updated,
            runningInstanceReach: current.effectiveSetting == payload.request.themeName
                ? .currentInstances : .unavailable,
            detail: current.effectiveSetting == payload.request.themeName
                ? "Recovered the acknowledged VS Code theme state by inspection."
                : overrideDetail(current.overrides),
            rollbackData: try encode(
                VSCodeThemeReceipt(
                    request: payload.request,
                    acknowledgement: nil,
                    recoveryInspection: current
                )
            )
        )
    }

    public func rollbackApply(plan: AdapterPlan, receipt: AdapterReceipt) async throws {
        _ = try await rollbackApplyWithReceipt(plan: plan, receipt: receipt)
    }

    public func recoverRollbackReceipt(
        plan: AdapterPlan,
        originalReceipt: AdapterReceipt
    ) async throws -> AdapterReceipt {
        let payload = try themePayload(from: plan)
        let before = try decodeInspection(plan.capturedPreChangeState)
        _ = try validateOriginalReceipt(originalReceipt, for: payload)
        let recoverySessionID = try await registeredSessionID(for: payload.expectation)
        let current: CompanionThemeInspection
        do {
            current = try await platform.inspectTheme(
                serverSessionID: recoverySessionID,
                matching: payload.expectation
            )
        } catch let error as VSCodeCompanionRequestError {
            throw VSCodeThemeAdapterError.requestFailed(error)
        }
        guard current.configuredSetting == before.configuredSetting else {
            throw VSCodeThemeAdapterError.externalSettingChanged
        }
        let undoRequest = VSCodeCompanionThemeRequest(
            protocolVersion: payload.request.protocolVersion,
            themeName: before.configuredSetting,
            expectedSetting: payload.request.themeName,
            target: payload.request.target
        )
        let active = before.configuredSetting == nil
            ? current.overrides.isEmpty
            : current.effectiveSetting == before.configuredSetting
        return AdapterReceipt(
            configurationState: .updated,
            runningInstanceReach: active ? .currentInstances : .unavailable,
            detail: active
                ? "Recovered the completed VS Code Undo by inspection."
                : overrideDetail(current.overrides),
            rollbackData: try encode(
                VSCodeThemeReceipt(
                    request: undoRequest,
                    acknowledgement: nil,
                    recoveryInspection: current
                )
            )
        )
    }

    public func rollbackApplyWithReceipt(
        plan: AdapterPlan,
        receipt: AdapterReceipt
    ) async throws -> AdapterReceipt {
        let payload = try themePayload(from: plan)
        let before = try decodeInspection(plan.capturedPreChangeState)
        _ = try validateOriginalReceipt(receipt, for: payload)
        let undoSessionID: String
        do {
            undoSessionID = try await registeredSessionID(for: payload.expectation)
        } catch let error as VSCodeThemeAdapterError {
            throw VSCodeRollbackNotStarted(cause: error)
        }
        let current: CompanionThemeInspection
        do {
            current = try await platform.inspectTheme(
                serverSessionID: undoSessionID,
                matching: payload.expectation
            )
        } catch let error as VSCodeCompanionRequestError {
            throw VSCodeRollbackNotStarted(cause: .requestFailed(error))
        }
        guard current.configuredSetting == payload.request.themeName else {
            throw VSCodeThemeAdapterError.externalSettingChanged
        }
        let undoRequest = VSCodeCompanionThemeRequest(
            protocolVersion: payload.request.protocolVersion,
            themeName: before.configuredSetting,
            expectedSetting: payload.request.themeName,
            target: payload.request.target
        )
        let outcome: CompanionApplyOutcome
        do {
            outcome = try await platform.applyTheme(
                undoRequest,
                serverSessionID: undoSessionID,
                matching: payload.expectation
            )
        } catch let error as VSCodeCompanionRequestError {
            switch error {
            case .timeout, .disconnected, .duplicateRequest, .malformedAcknowledgement,
                .targetUnavailable, .notRunning:
                throw VSCodeThemeRecoveryRequired(
                    targetInstanceID: plan.targetInstanceID,
                    requestError: error
                )
            case .staleRequest, .unsupportedProtocol:
                throw VSCodeThemeAdapterError.requestFailed(error)
            }
        }
        guard outcome.sessionID == undoSessionID else {
            throw VSCodeThemeRecoveryRequired(
                targetInstanceID: plan.targetInstanceID,
                requestError: .malformedAcknowledgement
            )
        }
        do {
            return try self.receipt(
                for: undoRequest,
                acknowledgement: outcome.acknowledgement
            )
        } catch VSCodeThemeAdapterError.requestFailed(.malformedAcknowledgement) {
            throw VSCodeThemeRecoveryRequired(
                targetInstanceID: plan.targetInstanceID,
                requestError: .malformedAcknowledgement
            )
        } catch VSCodeThemeAdapterError.updateFailed {
            throw VSCodeThemeRecoveryRequired(
                targetInstanceID: plan.targetInstanceID,
                requestError: .malformedAcknowledgement
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

    private func validateOriginalReceipt(
        _ receipt: AdapterReceipt,
        for payload: VSCodeThemePlanPayload
    ) throws -> VSCodeThemeReceipt {
        guard let rollbackData = receipt.rollbackData,
            let details = try? JSONDecoder().decode(
                VSCodeThemeReceipt.self,
                from: rollbackData
            ),
            details.request == payload.request
        else {
            throw VSCodeThemeAdapterError.malformedPlan
        }
        if let acknowledgement = details.acknowledgement {
            guard acknowledgement.protocolVersion == payload.request.protocolVersion,
                acknowledgement.requestedSetting == payload.request.themeName,
                acknowledgement.configuredSetting == payload.request.themeName
            else {
                throw VSCodeThemeAdapterError.malformedPlan
            }
        } else if let inspection = details.recoveryInspection {
            guard inspection.configuredSetting == payload.request.themeName else {
                throw VSCodeThemeAdapterError.malformedPlan
            }
        } else {
            throw VSCodeThemeAdapterError.malformedPlan
        }
        return details
    }

    private func registeredSessionID(
        for expectation: VSCodeRegistrationExpectation
    ) async throws -> String {
        guard let registration = await platform.registration(matching: expectation) else {
            throw VSCodeThemeAdapterError.notConnected
        }
        return registration.serverSessionID
    }

    private func themePayload(from plan: AdapterPlan) throws -> VSCodeThemePlanPayload {
        guard plan.adapterID == id,
            plan.adapterVersion == version,
            plan.payload.adapterID == id,
            plan.payload.adapterVersion == version,
            plan.payload.payloadVersion == payloadVersion,
            plan.targetInstanceID == Self.targetInstanceID(for: expectedRegistration),
            let payload = try? JSONDecoder().decode(
                VSCodeThemePlanPayload.self,
                from: plan.payload.payload
            ),
            payload.expectation == expectedRegistration,
            payload.request.protocolVersion == CompanionProtocol.currentVersion,
            payload.request.target == .global,
            payload.request.themeName == payload.theme.displayName,
            payload.artifact.themeName == payload.request.themeName,
            plan.sourceType == payload.theme.sourceType,
            plan.sourceRevision == payload.theme.sourceRevision
        else {
            throw VSCodeThemeAdapterError.malformedPlan
        }
        return payload
    }

    private func compileGeneratedTheme(_ theme: PreparedTheme) throws -> VSCodeThemeArtifact {
        let packID = theme.variantID.split(separator: "/").first.map(String.init) ?? "oh-my-theme"
        let packName = packID.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        let name = "\(packName) \(theme.variant.displayName)"
        let roles = theme.variant.roles
        func color(_ role: SemanticRole) throws -> String {
            guard let value = roles[role]?.rawValue else {
                throw VSCodeThemeAdapterError.malformedThemeArtifact
            }
            return value
        }
        return try VSCodeThemeArtifact(
            themeName: name,
            uiTheme: theme.variant.appearance == .dark ? "vs-dark" : "vs",
            colors: [
                "activityBar.background": color(.canvas),
                "activityBar.foreground": color(.primaryText),
                "editor.background": color(.canvas),
                "editor.foreground": color(.primaryText),
                "editor.selectionBackground": color(.selection),
                "editorLineNumber.foreground": color(.overlay),
                "sideBar.background": color(.surface),
                "sideBar.foreground": color(.secondaryText),
                "statusBar.background": color(.surface),
                "statusBar.foreground": color(.primaryText),
                "terminal.ansiBlack": color(.ansiBlack),
                "terminal.ansiBlue": color(.ansiBlue),
                "terminal.ansiCyan": color(.ansiCyan),
                "terminal.ansiGreen": color(.ansiGreen),
                "terminal.ansiMagenta": color(.ansiMagenta),
                "terminal.ansiRed": color(.ansiRed),
                "terminal.ansiWhite": color(.ansiWhite),
                "terminal.ansiYellow": color(.ansiYellow),
            ],
            tokenColors: [
                VSCodeTokenColor(
                    scopes: ["comment", "punctuation.definition.comment"],
                    foreground: color(.syntaxComment)
                ),
                VSCodeTokenColor(
                    scopes: ["keyword", "storage", "storage.type"],
                    foreground: color(.syntaxKeyword)
                ),
                VSCodeTokenColor(
                    scopes: ["string", "constant.other.symbol"],
                    foreground: color(.syntaxString)
                ),
            ]
        )
    }

    private func decodeInspection(_ data: Data?) throws -> CompanionThemeInspection {
        guard let data,
            let inspection = try? JSONDecoder().decode(CompanionThemeInspection.self, from: data)
        else {
            throw VSCodeThemeAdapterError.malformedPlan
        }
        return inspection
    }

    private func receipt(
        for request: VSCodeCompanionThemeRequest,
        acknowledgement: CompanionApplyThemeAckMessage
    ) throws -> AdapterReceipt {
        guard acknowledgement.protocolVersion == request.protocolVersion,
            acknowledgement.requestedSetting == request.themeName
        else {
            throw VSCodeThemeAdapterError.requestFailed(.malformedAcknowledgement)
        }
        let state: ConfigurationState
        let reach: ActivationReach
        let detail: String
        switch acknowledgement.status {
        case .applied:
            guard acknowledgement.configuredSetting == request.themeName,
                acknowledgement.previousSetting == request.expectedSetting,
                request.themeName == nil || acknowledgement.effectiveSetting == request.themeName
            else {
                throw VSCodeThemeAdapterError.requestFailed(.malformedAcknowledgement)
            }
            state = acknowledgement.previousSetting == request.themeName ? .unchanged : .updated
            reach = .currentInstances
            detail = "VS Code applied \(displaySetting(request.themeName)) in the intended profile/window."
        case .overridden:
            guard acknowledgement.configuredSetting == request.themeName,
                acknowledgement.previousSetting == request.expectedSetting,
                !acknowledgement.overrides.isEmpty
            else {
                throw VSCodeThemeAdapterError.requestFailed(.malformedAcknowledgement)
            }
            state = acknowledgement.previousSetting == request.themeName ? .unchanged : .updated
            reach = .unavailable
            detail = overrideDetail(acknowledgement.overrides)
        case .conflicted:
            throw VSCodeThemeAdapterError.externalSettingChanged
        case .unsupportedTheme:
            throw VSCodeThemeAdapterError.unsupportedTheme(
                request.themeName ?? "the default theme"
            )
        case .failed:
            guard let failure = acknowledgement.failure else {
                throw VSCodeThemeAdapterError.requestFailed(.malformedAcknowledgement)
            }
            throw VSCodeThemeAdapterError.updateFailed(
                code: failure.code,
                message: failure.message
            )
        }
        return AdapterReceipt(
            configurationState: state,
            runningInstanceReach: reach,
            detail: detail,
            rollbackData: try encode(
                VSCodeThemeReceipt(
                    request: request,
                    acknowledgement: acknowledgement
                )
            )
        )
    }

    private func overrideDetail(_ overrides: [CompanionOverride]) -> String {
        guard !overrides.isEmpty else {
            return "VS Code stored the requested profile theme, but it is not active in the intended window."
        }
        let scopes = overrides.map { override in
            switch override.scope {
            case .workspace: "workspace"
            case .workspaceFolder: "workspace folder"
            case .remote: "remote window"
            }
        }.joined(separator: ", ")
        return "VS Code stored the requested profile theme, but the current \(scopes) setting overrides it."
    }

    private func displaySetting(_ setting: String?) -> String {
        setting ?? "the default color theme"
    }

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
