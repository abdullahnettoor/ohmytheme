import Foundation

// MARK: - Effect

/// Outcomes produced by a ``CompanionServerSession`` in response to an
/// incoming frame or a caller-initiated request.
///
/// The session itself performs no I/O: callers translate `send` effects
/// into framed writes and `close` effects into socket shutdown.
/// `deliverAcknowledgement` surfaces a matched acknowledgement to the
/// caller so it can be recorded in an adapter receipt.
public enum CompanionServerEffect: Equatable, Sendable {
    case send(CompanionMessage)
    case close
    case deliverAcknowledgement(CompanionApplyThemeAckMessage)
}

// MARK: - Session state

/// The state machine that governs one companion connection on the
/// server side. The session validates registration, tracks outstanding
/// `apply_theme` requests, matches acknowledgements, and turns protocol
/// violations into `protocol_error` messages or connection closure.
///
/// The type is a `struct` so callers can compose it with their own
/// synchronization strategy. Everything is single-threaded and
/// side-effect free.
public struct CompanionServerSession {

    /// Provides monotonically fresh request identifiers for
    /// server-originated messages. Overridable so tests can produce
    /// deterministic IDs.
    public typealias UUIDProvider = @Sendable () -> UUID

    private enum State {
        case awaitingRegister
        case registered(sessionId: String, protocolVersion: Int)
        case closed
    }

    private var state: State = .awaitingRegister
    private var seenIncomingIDs: Set<UUID> = []
    private var outstandingRequests: [UUID: CompanionApplyThemeMessage] = [:]

    private let launchNonce: String
    private let supportedProtocolVersions: ClosedRange<Int>
    private let sessionIdProvider: @Sendable () -> String
    private let uuidProvider: UUIDProvider

    /// Number of `apply_theme` requests the server has sent that have
    /// not yet been acknowledged. Exposed for tests and diagnostics.
    public var outstandingRequestCount: Int { outstandingRequests.count }

    /// True after the extension has registered successfully and before
    /// the session is closed.
    public var isRegistered: Bool {
        if case .registered = state { return true } else { return false }
    }

    /// The session identifier assigned at register time, if any.
    public var negotiatedSessionID: String? {
        if case .registered(let id, _) = state { return id } else { return nil }
    }

    /// The protocol version negotiated at register time, if any.
    public var negotiatedProtocolVersion: Int? {
        if case .registered(_, let version) = state { return version } else { return nil }
    }

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

    /// Process a single frame body that just arrived from the peer.
    /// Returns the effects the caller must perform, in order.
    public mutating func receive(body: Data) -> [CompanionServerEffect] {
        if case .closed = state { return [] }

        let message: CompanionMessage
        do {
            message = try CompanionMessageCodec.decodeBody(body)
        } catch let error as CompanionProtocolError {
            return protocolErrorAndClose(error: error, requestId: nil)
        } catch {
            return protocolErrorAndClose(error: .malformedJSON, requestId: nil)
        }

        switch state {
        case .awaitingRegister:
            return receiveWhileAwaitingRegister(message)
        case .registered(_, let negotiatedVersion):
            guard message.protocolVersion == negotiatedVersion else {
                state = .closed
                return [
                    .send(
                        .protocolError(
                            CompanionProtocolErrorMessage(
                                protocolVersion: negotiatedVersion,
                                id: uuidProvider(),
                                requestId: message.id,
                                code: .unsupportedProtocolVersion,
                                message:
                                    "Message protocol version \(message.protocolVersion) does not match the negotiated version \(negotiatedVersion)."
                            )
                        )
                    ),
                    .close,
                ]
            }
            return receiveWhileRegistered(message)
        case .closed:
            return []
        }
    }

    /// Signal that the register timeout has elapsed. If the session has
    /// not yet registered, close it; otherwise do nothing.
    public mutating func onRegisterTimeout() -> [CompanionServerEffect] {
        if case .awaitingRegister = state {
            state = .closed
            return [.close]
        }
        return []
    }

    // MARK: - Outgoing requests

    /// Produce an `apply_theme` request targeting the registered
    /// extension. Returns an empty array when the session is not
    /// registered.
    public mutating func sendApplyTheme(
        themeName: String,
        target: CompanionApplyTarget = .global
    ) -> [CompanionServerEffect] {
        guard case .registered(let sessionId, let negotiatedVersion) = state else { return [] }
        let request = CompanionApplyThemeMessage(
            protocolVersion: negotiatedVersion,
            id: uuidProvider(),
            sessionId: sessionId,
            themeName: themeName,
            target: target
        )
        outstandingRequests[request.id] = request
        return [.send(.applyTheme(request))]
    }

    // MARK: - Handlers

    private mutating func receiveWhileAwaitingRegister(
        _ message: CompanionMessage
    ) -> [CompanionServerEffect] {
        guard case .register(let register) = message else {
            state = .closed
            return [
                .send(
                    .protocolError(
                        CompanionProtocolErrorMessage(
                            protocolVersion: CompanionProtocol.currentVersion,
                            id: uuidProvider(),
                            requestId: message.id,
                            code: .notRegistered,
                            message: "The first message on a companion connection must be `register`."
                        )
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

        case .applyThemeAck(let ack):
            if seenIncomingIDs.contains(ack.id) {
                return [
                    .send(
                        .protocolError(
                            CompanionProtocolErrorMessage(
                                protocolVersion: CompanionProtocol.currentVersion,
                                id: uuidProvider(),
                                requestId: ack.id,
                                code: .duplicateRequestID,
                                message: "This request identifier was already acknowledged."
                            )
                        )
                    )
                ]
            }
            guard outstandingRequests.removeValue(forKey: ack.id) != nil else {
                seenIncomingIDs.insert(ack.id)
                return [
                    .send(
                        .protocolError(
                            CompanionProtocolErrorMessage(
                                protocolVersion: CompanionProtocol.currentVersion,
                                id: uuidProvider(),
                                requestId: ack.id,
                                code: .unexpectedMessage,
                                message: "No apply_theme request is outstanding for this id."
                            )
                        )
                    )
                ]
            }
            seenIncomingIDs.insert(ack.id)
            return [.deliverAcknowledgement(ack)]

        case .protocolError:
            // Peer-reported protocol errors are surfaced to the caller
            // by dropping them into the effect list unchanged is not
            // useful here: the socket layer records them separately.
            // Returning an empty effect list keeps the connection open.
            return []

        case .applyTheme, .registerAck, .registerRejected:
            // These messages are only ever sent server-to-extension.
            // Seeing one from the extension is a protocol violation.
            state = .closed
            return [
                .send(
                    .protocolError(
                        CompanionProtocolErrorMessage(
                            protocolVersion: CompanionProtocol.currentVersion,
                            id: uuidProvider(),
                            requestId: message.id,
                            code: .unexpectedMessage,
                            message: "Message type is only valid from server to extension."
                        )
                    )
                ),
                .close,
            ]
        }
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
        requestId: UUID?
    ) -> [CompanionServerEffect] {
        state = .closed
        let code: CompanionProtocolErrorCode
        switch error {
        case .unsupportedProtocolVersion:
            code = .unsupportedProtocolVersion
        case .unsupportedType:
            code = .unsupportedType
        case .missingField:
            code = .missingRequiredField
        case .bodyTooLarge, .malformedJSON, .notObject, .invalidUUID,
            .invalidEnum, .invalidField:
            code = .malformedFrame
        }
        return [
            .send(
                .protocolError(
                    CompanionProtocolErrorMessage(
                        protocolVersion: CompanionProtocol.currentVersion,
                        id: uuidProvider(),
                        requestId: requestId,
                        code: code,
                        message: describe(error)
                    )
                )
            ),
            .close,
        ]
    }

    private func describe(_ error: CompanionProtocolError) -> String {
        switch error {
        case .bodyTooLarge(let size):
            return "Frame body of \(size) bytes exceeds the maximum."
        case .malformedJSON:
            return "Frame body is not valid JSON."
        case .notObject:
            return "Frame body is not a JSON object."
        case .missingField(let name):
            return "Required field '\(name)' is missing."
        case .unsupportedType(let type):
            return "Message type '\(type)' is not supported."
        case .unsupportedProtocolVersion(let version):
            return "Protocol version \(version) is not supported."
        case .invalidUUID(let raw):
            return "Value '\(raw)' is not a valid UUID."
        case .invalidEnum(let field, let value):
            return "Field '\(field)' has unsupported value '\(value)'."
        case .invalidField(let name):
            return "Field '\(name)' has an unexpected type."
        }
    }
}
