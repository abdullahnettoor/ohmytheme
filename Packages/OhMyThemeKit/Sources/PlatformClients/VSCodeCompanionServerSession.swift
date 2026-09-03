import Foundation

// MARK: - Registration

/// An authenticated companion registration retained by the server for identity
/// matching and durable connection receipts.
public struct CompanionRegistration: Codable, Equatable, Sendable {
    public let serverSessionID: String
    public let extensionVersion: String
    public let vscode: CompanionVSCodeIdentity
    public let capabilities: [String]
    public let currentSettings: [String: String]

    public init(
        serverSessionID: String,
        extensionVersion: String,
        vscode: CompanionVSCodeIdentity,
        capabilities: [String],
        currentSettings: [String: String]
    ) {
        self.serverSessionID = serverSessionID
        self.extensionVersion = extensionVersion
        self.vscode = vscode
        self.capabilities = capabilities
        self.currentSettings = currentSettings
    }
}

// MARK: - Effect

/// Outcomes produced by a ``CompanionServerSession`` in response to an
/// incoming frame or a caller-initiated request.
public enum CompanionServerEffect: Equatable, Sendable {
    case send(CompanionMessage)
    case close
    case deliverInspectionAcknowledgement(CompanionInspectThemeAckMessage)
    case deliverAcknowledgement(CompanionApplyThemeAckMessage)
    case failRequest(UUID, VSCodeCompanionRequestError)
}

// MARK: - Session state

/// The state machine for one companion connection. The socket layer owns
/// synchronization and executes the effects returned by this value.
public struct CompanionServerSession {
    public typealias UUIDProvider = @Sendable () -> UUID

    private enum State {
        case awaitingRegister
        case registered(sessionId: String, protocolVersion: Int)
        case closed
    }

    private enum OutstandingRequest {
        case inspect(CompanionInspectThemeMessage)
        case apply(CompanionApplyThemeMessage)
    }

    private var state: State = .awaitingRegister
    private var seenIncomingIDs: Set<UUID> = []
    private var outstandingRequests: [UUID: OutstandingRequest] = [:]
    private var acceptedRegistration: CompanionRegistration?

    private let launchNonce: String
    private let supportedProtocolVersions: ClosedRange<Int>
    private let sessionIdProvider: @Sendable () -> String
    private let uuidProvider: UUIDProvider

    /// Number of inspect and apply requests awaiting a reply.
    public var outstandingRequestCount: Int { outstandingRequests.count }

    public var isRegistered: Bool {
        if case .registered = state { return true }
        return false
    }

    public var negotiatedSessionID: String? {
        if case .registered(let id, _) = state { return id }
        return nil
    }

    public var negotiatedProtocolVersion: Int? {
        if case .registered(_, let version) = state { return version }
        return nil
    }

    public var registration: CompanionRegistration? { acceptedRegistration }

    public init(
        launchNonce: String,
        supportedProtocolVersions: ClosedRange<Int> = CompanionProtocol.supportedVersions,
        sessionIdProvider: @escaping @Sendable () -> String,
        uuidProvider: @escaping UUIDProvider = { UUID() }
    ) {
        self.launchNonce = launchNonce
        self.supportedProtocolVersions = supportedProtocolVersions
        self.sessionIdProvider = sessionIdProvider
        self.uuidProvider = uuidProvider
    }

    // MARK: - Incoming frames

    public mutating func receive(body: Data) -> [CompanionServerEffect] {
        if case .closed = state { return [] }

        let message: CompanionMessage
        do {
            message = try CompanionMessageCodec.decodeBody(body)
        } catch let error as CompanionProtocolError {
            return protocolErrorAndClose(
                error: error,
                correlatedRequestID: acknowledgementRequestID(in: body)
            )
        } catch {
            return protocolErrorAndClose(
                error: .malformedJSON,
                correlatedRequestID: acknowledgementRequestID(in: body)
            )
        }

        switch state {
        case .awaitingRegister:
            return receiveWhileAwaitingRegister(message)
        case .registered(_, let negotiatedVersion):
            guard message.protocolVersion == negotiatedVersion else {
                var effects = failCorrelatedRequest(
                    messageID: correlatedRequestID(for: message),
                    error: .unsupportedProtocol
                )
                state = .closed
                effects.append(
                    .send(
                        protocolError(
                            protocolVersion: negotiatedVersion,
                            requestId: message.id,
                            code: .unsupportedProtocolVersion,
                            message:
                                "Message protocol version \(message.protocolVersion) does not match the negotiated version \(negotiatedVersion)."
                        )
                    )
                )
                effects.append(.close)
                return effects
            }
            return receiveWhileRegistered(message)
        case .closed:
            return []
        }
    }

    public mutating func onRegisterTimeout() -> [CompanionServerEffect] {
        if case .awaitingRegister = state {
            state = .closed
            return [.close]
        }
        return []
    }

    // MARK: - Outgoing requests

    public mutating func sendInspectTheme() -> [CompanionServerEffect] {
        guard case .registered(let sessionId, let negotiatedVersion) = state else { return [] }
        let request = CompanionInspectThemeMessage(
            protocolVersion: negotiatedVersion,
            id: uuidProvider(),
            sessionId: sessionId
        )
        outstandingRequests[request.id] = .inspect(request)
        return [.send(.inspectTheme(request))]
    }

    public mutating func sendApplyTheme(
        _ request: VSCodeCompanionThemeRequest
    ) throws -> [CompanionServerEffect] {
        guard case .registered(let sessionId, let negotiatedVersion) = state else {
            throw VSCodeCompanionRequestError.disconnected
        }
        guard request.protocolVersion == negotiatedVersion else {
            throw VSCodeCompanionRequestError.unsupportedProtocol
        }
        let message = CompanionApplyThemeMessage(
            protocolVersion: request.protocolVersion,
            id: uuidProvider(),
            sessionId: sessionId,
            themeName: request.themeName,
            expectedSetting: request.expectedSetting,
            target: request.target
        )
        outstandingRequests[message.id] = .apply(message)
        return [.send(.applyTheme(message))]
    }

    /// Compatibility entry point for callers that only supply a theme name.
    public mutating func sendApplyTheme(
        themeName: String,
        target: CompanionApplyTarget = .global
    ) -> [CompanionServerEffect] {
        guard let protocolVersion = negotiatedProtocolVersion else { return [] }
        return (try? sendApplyTheme(
            VSCodeCompanionThemeRequest(
                protocolVersion: protocolVersion,
                themeName: themeName,
                expectedSetting: nil,
                target: target
            )
        )) ?? []
    }

    /// Stop tracking a request whose socket-level waiter timed out.
    public mutating func cancelRequest(id: UUID) {
        outstandingRequests.removeValue(forKey: id)
    }

    // MARK: - Handlers

    private mutating func receiveWhileAwaitingRegister(
        _ message: CompanionMessage
    ) -> [CompanionServerEffect] {
        guard case .register(let register) = message else {
            state = .closed
            return [
                .send(
                    protocolError(
                        requestId: message.id,
                        code: .notRegistered,
                        message: "The first message on a companion connection must be `register`."
                    )
                ),
                .close,
            ]
        }

        guard supportedProtocolVersions.contains(register.protocolVersion) else {
            return rejectRegister(id: register.id, reason: .unsupportedProtocol)
        }
        guard register.launchNonce == launchNonce else {
            return rejectRegister(id: register.id, reason: .invalidNonce)
        }
        guard register.capabilities.contains("colorTheme") else {
            return rejectRegister(id: register.id, reason: .missingCapability)
        }

        seenIncomingIDs.insert(register.id)
        let sessionId = sessionIdProvider()
        acceptedRegistration = CompanionRegistration(
            serverSessionID: sessionId,
            extensionVersion: register.extensionVersion,
            vscode: register.vscode,
            capabilities: register.capabilities,
            currentSettings: register.currentSettings
        )
        state = .registered(sessionId: sessionId, protocolVersion: register.protocolVersion)
        return [
            .send(
                .registerAck(
                    CompanionRegisterAckMessage(
                        protocolVersion: register.protocolVersion,
                        id: register.id,
                        sessionId: sessionId
                    )
                )
            )
        ]
    }

    private mutating func receiveWhileRegistered(
        _ message: CompanionMessage
    ) -> [CompanionServerEffect] {
        switch message {
        case .register(let register):
            return rejectRegister(id: register.id, reason: .duplicateRegistration)

        case .inspectThemeAck(let acknowledgement):
            return receiveInspectionAcknowledgement(acknowledgement)

        case .applyThemeAck(let acknowledgement):
            return receiveApplyAcknowledgement(acknowledgement)

        case .protocolError(let error):
            return receivePeerProtocolError(error)

        case .inspectTheme, .applyTheme, .registerAck, .registerRejected:
            state = .closed
            return [
                .send(
                    protocolError(
                        requestId: message.id,
                        code: .unexpectedMessage,
                        message: "Message type is only valid from server to extension."
                    )
                ),
                .close,
            ]
        }
    }

    private mutating func receiveInspectionAcknowledgement(
        _ acknowledgement: CompanionInspectThemeAckMessage
    ) -> [CompanionServerEffect] {
        if seenIncomingIDs.contains(acknowledgement.id) {
            return duplicateAcknowledgementEffects(id: acknowledgement.id)
        }
        guard let outstanding = outstandingRequests.removeValue(forKey: acknowledgement.id) else {
            return staleAcknowledgementEffects(id: acknowledgement.id, requestType: "inspect_theme")
        }
        seenIncomingIDs.insert(acknowledgement.id)
        guard case .inspect = outstanding else {
            return malformedAcknowledgementEffects(
                id: acknowledgement.id,
                message: "An inspect_theme_ack cannot acknowledge an apply_theme request."
            )
        }
        return [.deliverInspectionAcknowledgement(acknowledgement)]
    }

    private mutating func receiveApplyAcknowledgement(
        _ acknowledgement: CompanionApplyThemeAckMessage
    ) -> [CompanionServerEffect] {
        if seenIncomingIDs.contains(acknowledgement.id) {
            return duplicateAcknowledgementEffects(id: acknowledgement.id)
        }
        guard let outstanding = outstandingRequests.removeValue(forKey: acknowledgement.id) else {
            return staleAcknowledgementEffects(id: acknowledgement.id, requestType: "apply_theme")
        }
        seenIncomingIDs.insert(acknowledgement.id)
        guard case .apply(let request) = outstanding else {
            return malformedAcknowledgementEffects(
                id: acknowledgement.id,
                message: "An apply_theme_ack cannot acknowledge an inspect_theme request."
            )
        }
        guard acknowledgement.requestedSetting == request.themeName else {
            return malformedAcknowledgementEffects(
                id: acknowledgement.id,
                message: "The acknowledgement requestedSetting does not match the request."
            )
        }
        if acknowledgement.status == .applied || acknowledgement.status == .overridden {
            guard acknowledgement.configuredSetting == request.themeName else {
                return malformedAcknowledgementEffects(
                    id: acknowledgement.id,
                    message: "The acknowledgement configuredSetting does not match the request."
                )
            }
        }
        return [.deliverAcknowledgement(acknowledgement)]
    }

    private mutating func receivePeerProtocolError(
        _ error: CompanionProtocolErrorMessage
    ) -> [CompanionServerEffect] {
        guard let requestID = error.requestId,
            outstandingRequests.removeValue(forKey: requestID) != nil
        else {
            return []
        }
        seenIncomingIDs.insert(requestID)
        return [.failRequest(requestID, requestError(for: error.code))]
    }

    private mutating func duplicateAcknowledgementEffects(id: UUID) -> [CompanionServerEffect] {
        [
            .send(
                protocolError(
                    requestId: id,
                    code: .duplicateRequestID,
                    message: "This request identifier was already acknowledged."
                )
            )
        ]
    }

    private mutating func staleAcknowledgementEffects(
        id: UUID,
        requestType: String
    ) -> [CompanionServerEffect] {
        seenIncomingIDs.insert(id)
        return [
            .send(
                protocolError(
                    requestId: id,
                    code: .unexpectedMessage,
                    message: "No \(requestType) request is outstanding for this id."
                )
            )
        ]
    }

    private func malformedAcknowledgementEffects(
        id: UUID,
        message: String
    ) -> [CompanionServerEffect] {
        [
            .failRequest(id, .malformedAcknowledgement),
            .send(
                protocolError(
                    requestId: id,
                    code: .unexpectedMessage,
                    message: message
                )
            ),
        ]
    }

    private mutating func rejectRegister(
        id: UUID,
        reason: CompanionRegisterRejectionReason
    ) -> [CompanionServerEffect] {
        state = .closed
        return [
            .send(
                .registerRejected(
                    CompanionRegisterRejectedMessage(
                        protocolVersion: CompanionProtocol.currentVersion,
                        id: id,
                        reason: reason
                    )
                )
            ),
            .close,
        ]
    }

    private mutating func protocolErrorAndClose(
        error: CompanionProtocolError,
        correlatedRequestID: UUID?
    ) -> [CompanionServerEffect] {
        var effects: [CompanionServerEffect] = []
        if let requestID = correlatedRequestID,
            outstandingRequests.removeValue(forKey: requestID) != nil
        {
            seenIncomingIDs.insert(requestID)
            effects.append(.failRequest(requestID, .malformedAcknowledgement))
        }
        state = .closed
        effects.append(
            .send(
                protocolError(
                    requestId: correlatedRequestID,
                    code: error.wireCode,
                    message: error.wireMessage
                )
            )
        )
        effects.append(.close)
        return effects
    }

    private mutating func failCorrelatedRequest(
        messageID: UUID?,
        error: VSCodeCompanionRequestError
    ) -> [CompanionServerEffect] {
        guard let messageID,
            outstandingRequests.removeValue(forKey: messageID) != nil
        else {
            return []
        }
        seenIncomingIDs.insert(messageID)
        return [.failRequest(messageID, error)]
    }

    private func correlatedRequestID(for message: CompanionMessage) -> UUID? {
        switch message {
        case .inspectThemeAck, .applyThemeAck:
            return message.id
        case .protocolError(let error):
            return error.requestId
        case .register, .registerAck, .registerRejected, .inspectTheme, .applyTheme:
            return nil
        }
    }

    private func requestError(
        for code: CompanionProtocolErrorCode
    ) -> VSCodeCompanionRequestError {
        switch code {
        case .duplicateRequestID:
            return .duplicateRequest
        case .unexpectedMessage:
            return .staleRequest
        case .unsupportedProtocolVersion:
            return .unsupportedProtocol
        case .notRegistered:
            return .disconnected
        case .malformedFrame, .unsupportedType, .missingRequiredField:
            return .malformedAcknowledgement
        }
    }

    private func acknowledgementRequestID(in body: Data) -> UUID? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let type = object["type"] as? String,
            type == "inspect_theme_ack" || type == "apply_theme_ack",
            let rawID = object["id"] as? String,
            let id = UUID(uuidString: rawID),
            outstandingRequests[id] != nil
        else {
            return nil
        }
        return id
    }

    private func protocolError(
        protocolVersion: Int = CompanionProtocol.currentVersion,
        requestId: UUID?,
        code: CompanionProtocolErrorCode,
        message: String
    ) -> CompanionMessage {
        .protocolError(
            CompanionProtocolErrorMessage(
                protocolVersion: protocolVersion,
                id: uuidProvider(),
                requestId: requestId,
                code: code,
                message: message
            )
        )
    }
}
