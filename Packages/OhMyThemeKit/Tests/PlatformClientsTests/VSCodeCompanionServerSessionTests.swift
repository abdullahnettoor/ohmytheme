import Foundation
import Testing

@testable import PlatformClients

@Suite("VS Code companion server session")
struct VSCodeCompanionServerSessionTests {

    // MARK: - Fixtures

    private static func makeIdentity() -> CompanionVSCodeIdentity {
        CompanionVSCodeIdentity(
            edition: "vscode",
            version: "1.94.0",
            profileName: "Default",
            profileId: "profile-1",
            machineId: "machine-1",
            sessionId: "vsc-session",
            processId: 42,
            windowId: "window-1"
        )
    }

    private static func makeRegisterBody(
        protocolVersion: Int = 1,
        id: UUID = UUID(),
        launchNonce: String = "nonce-1"
    ) throws -> Data {
        try CompanionMessageCodec.encodeBody(
            .register(
                .init(
                    protocolVersion: protocolVersion,
                    id: id,
                    launchNonce: launchNonce,
                    extensionVersion: "0.1.0",
                    vscode: makeIdentity(),
                    capabilities: ["colorTheme"],
                    currentSettings: [:]
                )
            )
        )
    }

    private static func makeSession(
        launchNonce: String = "nonce-1",
        sessionId: String = "server-session-1"
    ) -> CompanionServerSession {
        CompanionServerSession(
            launchNonce: launchNonce,
            supportedProtocolVersions: 1...1,
            sessionIdProvider: { sessionId }
        )
    }

    // MARK: - Registration

    @Test("Successful register produces a register_ack and marks the session registered")
    func registerSucceeds() throws {
        var session = Self.makeSession()
        let registerId = UUID()
        let body = try Self.makeRegisterBody(id: registerId)

        let effects = session.receive(body: body)

        #expect(effects.count == 1)
        guard case .send(let outbound) = effects[0] else {
            Issue.record("expected send effect")
            return
        }
        guard case .registerAck(let ack) = outbound else {
            Issue.record("expected register_ack")
            return
        }
        #expect(ack.id == registerId)
        #expect(ack.sessionId == "server-session-1")
        #expect(session.isRegistered)
    }

    @Test("Register with an unsupported protocol version is rejected")
    func registerRejectsUnsupportedProtocol() throws {
        var session = Self.makeSession()

        // Build a raw register body announcing an out-of-range version so
        // it bypasses codec-level version rejection. We do this by
        // encoding a version-1 message then substituting the field.
        let body = try Self.makeRegisterBody(protocolVersion: 1)
        var raw = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        raw["protocolVersion"] = 99
        let mutated = try JSONSerialization.data(withJSONObject: raw)

        let effects = session.receive(body: mutated)
        guard case .send(.registerRejected(let rejection)) = effects.first else {
            Issue.record("expected register_rejected")
            return
        }
        #expect(rejection.reason == .unsupportedProtocol)
        #expect(effects.last == .close)
    }

    @Test("Register with the wrong launch nonce is rejected")
    func registerRejectsBadNonce() throws {
        var session = Self.makeSession(launchNonce: "expected")
        let body = try Self.makeRegisterBody(launchNonce: "stale")

        let effects = session.receive(body: body)
        guard case .send(.registerRejected(let rejection)) = effects.first else {
            Issue.record("expected register_rejected")
            return
        }
        #expect(rejection.reason == .invalidNonce)
        #expect(effects.last == .close)
        #expect(!session.isRegistered)
    }

    @Test("Register without the colorTheme capability is rejected")
    func registerRejectsMissingCapability() throws {
        var session = Self.makeSession()
        let body = try CompanionMessageCodec.encodeBody(
            .register(
                .init(
                    protocolVersion: 1,
                    id: UUID(),
                    launchNonce: "nonce-1",
                    extensionVersion: "0.1.0",
                    vscode: Self.makeIdentity(),
                    capabilities: [],
                    currentSettings: [:]
                )
            )
        )

        let effects = session.receive(body: body)
        guard case .send(.registerRejected(let rejection)) = effects.first else {
            Issue.record("expected register_rejected")
            return
        }
        #expect(rejection.reason == .missingCapability)
        #expect(effects.last == .close)
    }

    @Test("A second register on the same session is rejected as duplicate registration")
    func duplicateRegisterIsRejected() throws {
        var session = Self.makeSession()
        _ = session.receive(body: try Self.makeRegisterBody())

        let effects = session.receive(body: try Self.makeRegisterBody(id: UUID()))
        guard case .send(.registerRejected(let rejection)) = effects.first else {
            Issue.record("expected register_rejected")
            return
        }
        #expect(rejection.reason == .duplicateRegistration)
        #expect(effects.last == .close)
    }

    @Test("A non-register message before register is a protocol error")
    func nonRegisterBeforeRegisterIsError() throws {
        var session = Self.makeSession()
        let body = try CompanionMessageCodec.encodeBody(
            .applyThemeAck(
                .init(
                    protocolVersion: 1,
                    id: UUID(),
                    status: .applied,
                    effectiveSetting: "Some",
                    requestedSetting: "Some",
                    overrides: [],
                    failure: nil
                )
            )
        )

        let effects = session.receive(body: body)
        guard case .send(.protocolError(let error)) = effects.first else {
            Issue.record("expected protocol_error")
            return
        }
        #expect(error.code == .notRegistered)
        #expect(effects.last == .close)
    }

    // MARK: - Malformed frames

    @Test("A malformed frame body produces a protocol_error and closes")
    func malformedFrameIsError() throws {
        var session = Self.makeSession()
        let effects = session.receive(body: Data("not-json".utf8))

        guard case .send(.protocolError(let error)) = effects.first else {
            Issue.record("expected protocol_error")
            return
        }
        #expect(error.code == .malformedFrame)
        #expect(effects.last == .close)
    }

    // MARK: - Apply theme lifecycle

    @Test("Server-initiated apply_theme records the request as outstanding")
    func applyThemeIsRecorded() throws {
        var session = Self.makeSession()
        _ = session.receive(body: try Self.makeRegisterBody())

        let sent = session.sendApplyTheme(themeName: "Catppuccin Mocha")
        guard case .send(.applyTheme(let request)) = sent.first else {
            Issue.record("expected apply_theme effect")
            return
        }
        #expect(request.themeName == "Catppuccin Mocha")
        #expect(session.outstandingRequestCount == 1)
    }

    @Test("Apply theme is refused before the session is registered")
    func applyThemeRequiresRegistration() {
        var session = Self.makeSession()
        let effects = session.sendApplyTheme(themeName: "Catppuccin Mocha")

        // The session must not emit an outbound message and must
        // signal the caller that no send occurred.
        #expect(effects.isEmpty)
        #expect(session.outstandingRequestCount == 0)
    }

    @Test("An acknowledgement for an outstanding request matches and clears it")
    func acknowledgementMatchesOutstandingRequest() throws {
        var session = Self.makeSession()
        _ = session.receive(body: try Self.makeRegisterBody())

        guard case .send(.applyTheme(let sent))? = session.sendApplyTheme(themeName: "Mocha").first
        else {
            Issue.record("failed to send apply_theme")
            return
        }

        let ackBody = try CompanionMessageCodec.encodeBody(
            .applyThemeAck(
                .init(
                    protocolVersion: 1,
                    id: sent.id,
                    status: .applied,
                    effectiveSetting: "Mocha",
                    requestedSetting: "Mocha",
                    overrides: [],
                    failure: nil
                )
            )
        )

        let effects = session.receive(body: ackBody)
        #expect(
            effects.isEmpty
                || effects.allSatisfy { effect in
                    if case .deliverAcknowledgement = effect { return true } else { return false }
                })
        #expect(session.outstandingRequestCount == 0)
    }

    @Test("An acknowledgement for an unknown request id is a stale request")
    func staleAcknowledgementIsError() throws {
        var session = Self.makeSession()
        _ = session.receive(body: try Self.makeRegisterBody())

        let staleAck = try CompanionMessageCodec.encodeBody(
            .applyThemeAck(
                .init(
                    protocolVersion: 1,
                    id: UUID(),
                    status: .applied,
                    effectiveSetting: "Mocha",
                    requestedSetting: "Mocha",
                    overrides: [],
                    failure: nil
                )
            )
        )

        let effects = session.receive(body: staleAck)
        guard case .send(.protocolError(let error))? = effects.first else {
            Issue.record("expected protocol_error")
            return
        }
        #expect(error.code == .unexpectedMessage)
        // The connection remains open — a single stale ack is a bug,
        // not a fatal breach of protocol.
        #expect(!effects.contains(.close))
    }

    @Test("A second acknowledgement for the same request id is a duplicate")
    func duplicateAcknowledgementIsError() throws {
        var session = Self.makeSession()
        _ = session.receive(body: try Self.makeRegisterBody())

        guard case .send(.applyTheme(let sent))? = session.sendApplyTheme(themeName: "Mocha").first
        else {
            Issue.record("failed to send apply_theme")
            return
        }
        let ackBody = try CompanionMessageCodec.encodeBody(
            .applyThemeAck(
                .init(
                    protocolVersion: 1,
                    id: sent.id,
                    status: .applied,
                    effectiveSetting: "Mocha",
                    requestedSetting: "Mocha",
                    overrides: [],
                    failure: nil
                )
            )
        )
        _ = session.receive(body: ackBody)
        let duplicate = session.receive(body: ackBody)

        guard case .send(.protocolError(let error))? = duplicate.first else {
            Issue.record("expected protocol_error")
            return
        }
        #expect(error.code == .duplicateRequestID)
        #expect(error.requestId == sent.id)
    }

    @Test("A post-register message with a mismatched protocol version is a protocol error")
    func mismatchedProtocolVersionAfterRegisterIsError() throws {
        var session = Self.makeSession()
        _ = session.receive(body: try Self.makeRegisterBody())

        // Craft an apply_theme_ack whose protocol version does not match
        // the value the register negotiated.
        let ackBody = try CompanionMessageCodec.encodeBody(
            .applyThemeAck(
                .init(
                    protocolVersion: 1,
                    id: UUID(),
                    status: .applied,
                    effectiveSetting: "X",
                    requestedSetting: "X",
                    overrides: [],
                    failure: nil
                )
            )
        )
        var raw = try JSONSerialization.jsonObject(with: ackBody) as! [String: Any]
        raw["protocolVersion"] = 99
        let mutated = try JSONSerialization.data(withJSONObject: raw)

        let effects = session.receive(body: mutated)
        guard case .send(.protocolError(let error))? = effects.first else {
            Issue.record("expected protocol_error")
            return
        }
        #expect(error.code == .unsupportedProtocolVersion)
        #expect(effects.last == .close)
    }

    // MARK: - Timeouts

    @Test("A register timeout closes the session without sending register_ack")
    func registerTimeoutClosesSession() {
        var session = Self.makeSession()
        let effects = session.onRegisterTimeout()

        #expect(effects == [.close])
        #expect(!session.isRegistered)
    }

    @Test("A register timeout after registration is a no-op")
    func registerTimeoutAfterRegistrationIsNoop() throws {
        var session = Self.makeSession()
        _ = session.receive(body: try Self.makeRegisterBody())

        let effects = session.onRegisterTimeout()
        #expect(effects.isEmpty)
        #expect(session.isRegistered)
    }
}
