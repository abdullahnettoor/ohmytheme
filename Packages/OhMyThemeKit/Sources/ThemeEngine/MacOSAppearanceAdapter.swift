import CryptoKit
import Foundation
import Persistence
import PlatformClients
import ThemeModel

public struct MacOSAppearanceDiscoveryReport: Codable, Equatable, Sendable {
    public let targetInstanceID: TargetInstanceID
    public let requiredPermissions: [String]

    public init(targetInstanceID: TargetInstanceID, requiredPermissions: [String]) {
        self.targetInstanceID = targetInstanceID
        self.requiredPermissions = requiredPermissions
    }
}

public struct MacOSAppearanceApplyPayload: Codable, Equatable, Sendable {
    public let baseline: AppearanceSnapshot?
    public let intended: AppearanceSnapshot
    public let preparationIssue: MacOSAppearanceAdapterError?

    public init(
        baseline: AppearanceSnapshot?,
        intended: AppearanceSnapshot,
        preparationIssue: MacOSAppearanceAdapterError? = nil
    ) {
        self.baseline = baseline
        self.intended = intended
        self.preparationIssue = preparationIssue
    }
}

public enum MacOSAppearanceAdapterError: Error, Codable, Equatable, Sendable, CapabilityOutcomeError {
    case unsupportedInstance(TargetInstanceID)
    case permissionDenied
    case permissionRevoked
    case targetUnavailable
    case automationFailure(code: Int, message: String)
    case verificationFailed(expected: AppearanceSnapshot, observed: AppearanceSnapshot)
    case malformedPlan
    case staleState
    case restorationConflict

    public var capabilityConfigurationState: ConfigurationState {
        switch self {
        case .permissionDenied, .permissionRevoked:
            return .permissionRequired
        case .targetUnavailable:
            return .unavailable
        case .restorationConflict:
            return .conflicted
        case .unsupportedInstance, .automationFailure, .verificationFailed, .malformedPlan, .staleState:
            return .failed
        }
    }

    public var capabilityActivationReach: ActivationReach {
        .unavailable
    }

    public var capabilityOutcomeDetail: String {
        switch self {
        case .unsupportedInstance(let id):
            return "Unsupported macOS appearance Target Instance: \(id.rawValue)."
        case .permissionDenied:
            return "Automation permission was denied. Allow Oh My Theme to control System Events, then try again."
        case .permissionRevoked:
            return "Automation permission was revoked. Re-enable System Events access, then try again."
        case .targetUnavailable:
            return "System Events is unavailable, so macOS appearance could not be changed."
        case .automationFailure(let code, let message):
            return "System Events automation failed (\(code)): \(message)"
        case .verificationFailed(let expected, let observed):
            return
                "Appearance verification failed: expected darkMode=\(expected.darkMode), observed darkMode=\(observed.darkMode)."
        case .malformedPlan:
            return "The macOS appearance plan is malformed or incompatible."
        case .staleState:
            return "The macOS appearance operation did not reach its intended state."
        case .restorationConflict:
            return "System appearance changed outside Oh My Theme; restoration was refused."
        }
    }
}

public actor MacOSAppearanceAdapter: RecoverableApplyAdapter {
    public let id = "macos.appearance"
    public let version = "1.0.0"
    public let payloadVersion = "1"

    public static let capabilityID = "appearance"
    public static let systemTargetInstanceID = TargetInstanceID(rawValue: "macos.appearance:system")
    public static let automationPermissionDescription =
        "Automation access to System Events is required to read and change the system Light/Dark appearance."

    private let platform: any MacOSAppearancePlatform

    public init(platform: any MacOSAppearancePlatform = MacOSAppearanceClient()) {
        self.platform = platform
    }

    // Discovery deliberately performs no System Events request. The caller can
    // show the permission disclosure immediately before connection triggers the
    // first read and, on a clean machine, macOS presents its consent prompt.
    public func discover() -> MacOSAppearanceDiscoveryReport {
        MacOSAppearanceDiscoveryReport(
            targetInstanceID: Self.systemTargetInstanceID,
            requiredPermissions: [Self.automationPermissionDescription]
        )
    }

    // MARK: - Connection

    public func prepareConnection(
        instance: ConnectedTargetInstance,
        approveLinkedSource: Bool = false
    ) async throws -> ConnectionPlan {
        _ = approveLinkedSource
        try validate(instance)
        let baseline = try readAppearance(permissionFailure: .permissionDenied)
        let baselineData = try encode(baseline)

        return ConnectionPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            capturedPreChangeState: baselineData,
            intendedChangeDigest: digest(of: baselineData),
            staleStateToken: digest(of: baselineData),
            expectedSideEffects: [
                "Records the current system Light/Dark appearance so it can be restored."
            ],
            requiredPermissions: [Self.automationPermissionDescription],
            userActions: [],
            opaquePayload: baselineData,
            requiresApproval: false
        )
    }

    public func connect(_ plan: ConnectionPlan) async throws -> ConnectionReceipt {
        try await revalidateConnection(plan: plan)
        return ConnectionReceipt(
            configurationState: .unchanged,
            runningInstanceReach: .currentInstances,
            detail: "Automation access is available; recorded the current system appearance for restoration."
        )
    }

    public func revalidateConnection(plan: ConnectionPlan) async throws {
        guard plan.adapterID == id,
            plan.adapterVersion == version,
            plan.targetInstanceID == Self.systemTargetInstanceID
        else {
            throw MacOSAppearanceAdapterError.malformedPlan
        }
        let baseline: AppearanceSnapshot = try decode(plan.capturedPreChangeState)
        let current = try readAppearance(permissionFailure: .permissionRevoked)
        guard current == baseline else {
            throw WriteBoundaryConflict(
                targetInstanceID: plan.targetInstanceID,
                detail: "System appearance changed since connection was prepared."
            )
        }
    }

    public func classifyConnection(plan: ConnectionPlan) async throws -> ReconciliationClassification {
        guard plan.adapterID == id,
            plan.adapterVersion == version,
            plan.targetInstanceID == Self.systemTargetInstanceID
        else {
            throw MacOSAppearanceAdapterError.malformedPlan
        }
        do {
            let baseline: AppearanceSnapshot = try decode(plan.capturedPreChangeState)
            return try platform.read() == baseline ? .beforeChange : .conflicting
        } catch {
            return .conflicting
        }
    }

    public func restoreConnection(
        instance: ConnectedTargetInstance,
        baseline: Data
    ) async throws -> ConnectionReceipt {
        try validate(instance)
        let recorded: AppearanceSnapshot = try decode(baseline)
        let current = try readAppearance(permissionFailure: .permissionRevoked)
        guard current == recorded else {
            throw MacOSAppearanceAdapterError.restorationConflict
        }
        return ConnectionReceipt(
            configurationState: .unchanged,
            runningInstanceReach: .currentInstances,
            detail: "System appearance already matches its recorded Connection Baseline."
        )
    }

    // MARK: - Disconnect

    public func prepareDisconnect(
        instance: ConnectedTargetInstance,
        baseline: StoredConnectionBaseline,
        baselineData: Data
    ) async throws -> DisconnectPlan {
        try validate(instance)
        let recorded: AppearanceSnapshot = try decode(baselineData)
        let current = try readAppearance(permissionFailure: .permissionRevoked)
        guard current == recorded else {
            throw MacOSAppearanceAdapterError.restorationConflict
        }
        return DisconnectPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            baselineReference: baseline.baselineReference,
            staleStateToken: digest(of: try encode(current)),
            opaquePayload: try encode(recorded)
        )
    }

    public func disconnect(_ plan: DisconnectPlan, baseline: Data) async throws -> AdapterReceipt {
        _ = baseline
        try await revalidateDisconnect(plan: plan)
        return AdapterReceipt(
            configurationState: .unchanged,
            runningInstanceReach: .currentInstances,
            detail: "System appearance already matches its Connection Baseline; disconnect is a no-op."
        )
    }

    public func revalidateDisconnect(plan: DisconnectPlan) async throws {
        guard plan.adapterID == id,
            plan.adapterVersion == version,
            plan.targetInstanceID == Self.systemTargetInstanceID,
            let baselineData = plan.opaquePayload
        else {
            throw MacOSAppearanceAdapterError.malformedPlan
        }
        let baseline: AppearanceSnapshot = try decode(baselineData)
        let current = try readAppearance(permissionFailure: .permissionRevoked)
        guard current == baseline,
            plan.staleStateToken == digest(of: try encode(current))
        else {
            throw WriteBoundaryConflict(
                targetInstanceID: plan.targetInstanceID,
                detail: "System appearance changed since disconnect was prepared."
            )
        }
    }

    public func classifyDisconnect(plan: DisconnectPlan) async throws -> ReconciliationClassification {
        guard plan.adapterID == id,
            plan.adapterVersion == version,
            plan.targetInstanceID == Self.systemTargetInstanceID,
            let baselineData = plan.opaquePayload
        else {
            throw MacOSAppearanceAdapterError.malformedPlan
        }
        do {
            let baseline: AppearanceSnapshot = try decode(baselineData)
            return try platform.read() == baseline ? .intendedAfterChange : .conflicting
        } catch {
            return .conflicting
        }
    }

    // MARK: - Apply

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
        _ = connectionBaseline
        try validate(instance)
        let intended = AppearanceSnapshot(darkMode: theme.variant.appearance == .dark)

        let payload: MacOSAppearanceApplyPayload
        do {
            payload = MacOSAppearanceApplyPayload(baseline: try platform.read(), intended: intended)
        } catch let failure as AppleScriptFailure {
            payload = MacOSAppearanceApplyPayload(
                baseline: nil,
                intended: intended,
                preparationIssue: Self.adapterError(for: failure, permissionFailure: .permissionRevoked)
            )
        }

        let payloadData = try encode(payload)
        let capturedData = try payload.baseline.map(encode)
        return AdapterPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            capabilityID: Self.capabilityID,
            payload: AdapterPayloadEnvelope(
                adapterID: id,
                adapterVersion: version,
                payloadVersion: payloadVersion,
                payload: payloadData
            ),
            intendedChangeDigest: digest(of: payloadData),
            capturedPreChangeState: capturedData,
            staleStateToken: capturedData.map(digest),
            expectedSideEffects: [
                "Sets the system appearance to \(intended.darkMode ? "Dark" : "Light").",
                "Does not change the macOS accent color.",
            ],
            requiredPermissions: [Self.automationPermissionDescription],
            sourceType: theme.sourceType,
            sourceRevision: theme.sourceRevision,
            activationReach: .currentInstances,
            setupNeeds: Self.setupNeeds(for: payload.preparationIssue),
            conflicts: []
        )
    }

    public func revalidateApply(plan: AdapterPlan) async throws {
        let payload = try applyPayload(from: plan)
        if let issue = payload.preparationIssue {
            throw issue
        }
        guard let baseline = payload.baseline else {
            throw MacOSAppearanceAdapterError.malformedPlan
        }
        let current = try readAppearance(permissionFailure: .permissionRevoked)
        if current == baseline || current == payload.intended {
            return
        }
        throw WriteBoundaryConflict(
            targetInstanceID: plan.targetInstanceID,
            detail: "System appearance changed since the preview was prepared."
        )
    }

    public func apply(_ plan: AdapterPlan) async throws -> AdapterReceipt {
        try await revalidateApply(plan: plan)
        let payload = try applyPayload(from: plan)
        let current = try readAppearance(permissionFailure: .permissionRevoked)

        if current == payload.intended {
            return try receipt(for: payload, configurationState: .unchanged)
        }

        let result: AppearanceApplyResult
        do {
            result = try platform.apply(darkMode: payload.intended.darkMode)
        } catch let failure as AppleScriptFailure {
            throw Self.adapterError(for: failure, permissionFailure: .permissionRevoked)
        }

        switch result {
        case .applied(_, let observed):
            guard observed == payload.intended else {
                throw MacOSAppearanceAdapterError.verificationFailed(
                    expected: payload.intended,
                    observed: observed
                )
            }
            return try receipt(for: payload, configurationState: .updated)
        case .unchanged(let observed):
            guard observed == payload.intended else {
                throw MacOSAppearanceAdapterError.verificationFailed(
                    expected: payload.intended,
                    observed: observed
                )
            }
            return try receipt(for: payload, configurationState: .unchanged)
        case .verificationFailed(_, let expected, let observed):
            throw MacOSAppearanceAdapterError.verificationFailed(expected: expected, observed: observed)
        }
    }

    public func classifyApply(plan: AdapterPlan) async throws -> ReconciliationClassification {
        let payload = try applyPayload(from: plan)
        guard payload.preparationIssue == nil, let baseline = payload.baseline else {
            return .conflicting
        }
        do {
            let current = try platform.read()
            if current == payload.intended { return .intendedAfterChange }
            if current == baseline { return .beforeChange }
            return .conflicting
        } catch {
            return .conflicting
        }
    }

    public func recoverApplyReceipt(plan: AdapterPlan) async throws -> AdapterReceipt {
        switch try await classifyApply(plan: plan) {
        case .intendedAfterChange:
            let payload = try applyPayload(from: plan)
            let state: ConfigurationState = payload.baseline == payload.intended ? .unchanged : .updated
            return try receipt(
                for: payload,
                configurationState: state,
                detail: "Recovered the system appearance Apply receipt."
            )
        case .beforeChange:
            throw MacOSAppearanceAdapterError.staleState
        case .conflicting:
            throw MacOSAppearanceAdapterError.restorationConflict
        }
    }

    public func rollbackApply(plan: AdapterPlan, receipt: AdapterReceipt) async throws {
        _ = try applyPayload(from: plan)
        guard let rollbackData = receipt.rollbackData else {
            throw MacOSAppearanceAdapterError.malformedPlan
        }
        let payload: MacOSAppearanceApplyPayload = try decode(rollbackData)
        guard let baseline = payload.baseline else {
            throw MacOSAppearanceAdapterError.malformedPlan
        }
        let current = try readAppearance(permissionFailure: .permissionRevoked)
        guard current == payload.intended else {
            throw MacOSAppearanceAdapterError.restorationConflict
        }
        guard baseline != payload.intended else { return }

        let result: AppearanceApplyResult
        do {
            result = try platform.restore(baseline)
        } catch let failure as AppleScriptFailure {
            throw Self.adapterError(for: failure, permissionFailure: .permissionRevoked)
        }
        switch result {
        case .applied(_, let observed), .unchanged(let observed):
            guard observed == baseline else {
                throw MacOSAppearanceAdapterError.verificationFailed(expected: baseline, observed: observed)
            }
        case .verificationFailed(_, let expected, let observed):
            throw MacOSAppearanceAdapterError.verificationFailed(expected: expected, observed: observed)
        }
    }

    // MARK: - Helpers

    private static let automationPermissionAction = UserAction(
        title: "Allow Automation access",
        detail: automationPermissionDescription
    )

    private func validate(_ instance: ConnectedTargetInstance) throws {
        guard instance.id == Self.systemTargetInstanceID, instance.adapterID == id else {
            throw MacOSAppearanceAdapterError.unsupportedInstance(instance.id)
        }
    }

    private func applyPayload(from plan: AdapterPlan) throws -> MacOSAppearanceApplyPayload {
        guard plan.adapterID == id,
            plan.adapterVersion == version,
            plan.targetInstanceID == Self.systemTargetInstanceID,
            plan.payload.adapterID == id,
            plan.payload.adapterVersion == version,
            plan.payload.payloadVersion == payloadVersion
        else {
            throw MacOSAppearanceAdapterError.malformedPlan
        }
        return try decode(plan.payload.payload)
    }

    private func readAppearance(permissionFailure: MacOSAppearanceAdapterError) throws -> AppearanceSnapshot {
        do {
            return try platform.read()
        } catch let failure as AppleScriptFailure {
            throw Self.adapterError(for: failure, permissionFailure: permissionFailure)
        }
    }

    private static func setupNeeds(for issue: MacOSAppearanceAdapterError?) -> [UserAction] {
        guard case .permissionRevoked = issue else { return [] }
        return [automationPermissionAction]
    }

    private static func adapterError(
        for failure: AppleScriptFailure,
        permissionFailure: MacOSAppearanceAdapterError
    ) -> MacOSAppearanceAdapterError {
        switch failure {
        case .notAuthorized:
            return permissionFailure
        case .targetUnavailable:
            return .targetUnavailable
        case .executionFailed(let code, let message):
            return .automationFailure(code: code, message: message)
        }
    }

    private func receipt(
        for payload: MacOSAppearanceApplyPayload,
        configurationState: ConfigurationState,
        detail: String? = nil
    ) throws -> AdapterReceipt {
        AdapterReceipt(
            configurationState: configurationState,
            runningInstanceReach: .currentInstances,
            detail: detail
                ?? (configurationState == .unchanged
                    ? "System appearance was already \(payload.intended.darkMode ? "Dark" : "Light")."
                    : "Set system appearance to \(payload.intended.darkMode ? "Dark" : "Light")."),
            rollbackData: try encode(payload)
        )
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
            throw MacOSAppearanceAdapterError.malformedPlan
        }
    }

    private func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
