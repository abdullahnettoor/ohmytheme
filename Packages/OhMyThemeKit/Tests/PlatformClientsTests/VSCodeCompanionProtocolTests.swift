import Foundation
import Testing

@testable import PlatformClients

@Suite("VS Code companion protocol codec")
struct VSCodeCompanionProtocolTests {

    // MARK: - Framing

    @Test("Framing prefixes the JSON body with its big-endian length")
    func framingPrefixesBigEndianLength() throws {
        let body = Data(#"{"protocolVersion":1,"type":"register_ack","id":"x","sessionId":"s"}"#.utf8)

        let framed = CompanionFrame.encode(body: body)

        #expect(framed.count == body.count + 4)
        let prefix = framed.prefix(4)
        let lengthValue = prefix.withUnsafeBytes { raw -> UInt32 in
            var value: UInt32 = 0
            for byte in raw { value = (value << 8) | UInt32(byte) }
            return value
        }
        #expect(lengthValue == UInt32(body.count))
        #expect(Data(framed.dropFirst(4)) == body)
    }

    @Test("Decoder returns a single frame from an exact buffer")
    func decoderReturnsExactFrame() throws {
        let body = Data(#"{"protocolVersion":1,"type":"register_ack","id":"x","sessionId":"s"}"#.utf8)
        let framed = CompanionFrame.encode(body: body)

        var decoder = CompanionFrameDecoder()
        decoder.append(framed)

        let frame = try decoder.nextFrame()
        #expect(frame == body)
        #expect(try decoder.nextFrame() == nil)
    }

    @Test("Decoder returns nil when only a partial length header has arrived")
    func decoderWaitsForFullHeader() throws {
        var decoder = CompanionFrameDecoder()
        decoder.append(Data([0x00, 0x00]))

        #expect(try decoder.nextFrame() == nil)
    }

    @Test("Decoder returns nil when the body has not fully arrived")
    func decoderWaitsForFullBody() throws {
        let body = Data(#"{"protocolVersion":1}"#.utf8)
        let framed = CompanionFrame.encode(body: body)
        let half = framed.count - 3

        var decoder = CompanionFrameDecoder()
        decoder.append(framed.prefix(half))

        #expect(try decoder.nextFrame() == nil)

        decoder.append(framed.suffix(from: half))
        #expect(try decoder.nextFrame() == body)
    }

    @Test("Decoder yields consecutive frames concatenated in the same buffer")
    func decoderYieldsConsecutiveFrames() throws {
        let first = Data(#"{"protocolVersion":1,"type":"a"}"#.utf8)
        let second = Data(#"{"protocolVersion":1,"type":"b"}"#.utf8)

        var decoder = CompanionFrameDecoder()
        decoder.append(CompanionFrame.encode(body: first) + CompanionFrame.encode(body: second))

        #expect(try decoder.nextFrame() == first)
        #expect(try decoder.nextFrame() == second)
        #expect(try decoder.nextFrame() == nil)
    }

    @Test("Decoder rejects a frame whose body exceeds the maximum size")
    func decoderRejectsOversizedFrame() throws {
        let oversize = UInt32(CompanionFrameDecoder.maxBodySize + 1)
        var header = Data(count: 4)
        header[0] = UInt8((oversize >> 24) & 0xFF)
        header[1] = UInt8((oversize >> 16) & 0xFF)
        header[2] = UInt8((oversize >> 8) & 0xFF)
        header[3] = UInt8(oversize & 0xFF)

        var decoder = CompanionFrameDecoder()
        decoder.append(header)

        #expect(throws: CompanionProtocolError.self) {
            try decoder.nextFrame()
        }
    }

    // MARK: - Message decoding

    @Test("Register message round-trips through the codec")
    func registerRoundTrips() throws {
        let vscode = CompanionVSCodeIdentity(
            edition: "vscode",
            version: "1.94.0",
            profileName: "Default",
            profileId: "profile-1",
            machineId: "machine-1",
            sessionId: "session-1",
            processId: 12_345,
            windowId: "window-1"
        )
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let register = CompanionMessage.register(
            .init(
                protocolVersion: 1,
                id: uuid,
                launchNonce: "nonce-abc",
                extensionVersion: "0.1.0",
                vscode: vscode,
                capabilities: ["colorTheme"],
                currentSettings: ["workbench.colorTheme": "Old"]
            )
        )

        let encoded = try CompanionMessageCodec.encodeBody(register)
        let decoded = try CompanionMessageCodec.decodeBody(encoded)

        #expect(decoded == register)
    }

    @Test("Register acknowledgement round-trips through the codec")
    func registerAckRoundTrips() throws {
        let uuid = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let ack = CompanionMessage.registerAck(
            .init(protocolVersion: 1, id: uuid, sessionId: "s-1")
        )

        let encoded = try CompanionMessageCodec.encodeBody(ack)
        let decoded = try CompanionMessageCodec.decodeBody(encoded)

        #expect(decoded == ack)
    }

    @Test("Register rejected round-trips with its reason")
    func registerRejectedRoundTrips() throws {
        let uuid = UUID()
        let reasons: [CompanionRegisterRejectionReason] = [
            .unsupportedProtocol,
            .invalidNonce,
            .duplicateRegistration,
            .missingCapability,
            .unauthenticatedPeer,
        ]
        for reason in reasons {
            let message = CompanionMessage.registerRejected(
                .init(protocolVersion: 1, id: uuid, reason: reason)
            )
            let encoded = try CompanionMessageCodec.encodeBody(message)
            let decoded = try CompanionMessageCodec.decodeBody(encoded)
            #expect(decoded == message)
        }
    }

    @Test("Apply theme request round-trips")
    func applyThemeRoundTrips() throws {
        let uuid = UUID()
        let request = CompanionMessage.applyTheme(
            .init(
                protocolVersion: 1,
                id: uuid,
                sessionId: "s-1",
                themeName: "Catppuccin Mocha",
                target: .global
            )
        )
        let encoded = try CompanionMessageCodec.encodeBody(request)
        let decoded = try CompanionMessageCodec.decodeBody(encoded)
        #expect(decoded == request)
    }

    @Test("Apply theme acknowledgement round-trips with overrides and failure")
    func applyThemeAckRoundTrips() throws {
        let uuid = UUID()

        let applied = CompanionMessage.applyThemeAck(
            .init(
                protocolVersion: 1,
                id: uuid,
                status: .applied,
                effectiveSetting: "Catppuccin Mocha",
                requestedSetting: "Catppuccin Mocha",
                overrides: [],
                failure: nil
            )
        )
        #expect(
            try CompanionMessageCodec.decodeBody(CompanionMessageCodec.encodeBody(applied))
                == applied
        )

        let overridden = CompanionMessage.applyThemeAck(
            .init(
                protocolVersion: 1,
                id: uuid,
                status: .overridden,
                effectiveSetting: "Some Other",
                requestedSetting: "Catppuccin Mocha",
                overrides: [
                    .init(scope: .workspace, folder: nil, value: "Some Other"),
                    .init(scope: .workspaceFolder, folder: "/repo", value: "Other"),
                ],
                failure: nil
            )
        )
        #expect(
            try CompanionMessageCodec.decodeBody(CompanionMessageCodec.encodeBody(overridden))
                == overridden
        )

        let failed = CompanionMessage.applyThemeAck(
            .init(
                protocolVersion: 1,
                id: uuid,
                status: .failed,
                effectiveSetting: nil,
                requestedSetting: "Catppuccin Mocha",
                overrides: [],
                failure: .init(code: "update_threw", message: "boom")
            )
        )
        #expect(
            try CompanionMessageCodec.decodeBody(CompanionMessageCodec.encodeBody(failed))
                == failed
        )
    }

    @Test("Protocol error round-trips with its code and optional requestId")
    func protocolErrorRoundTrips() throws {
        let uuid = UUID()
        let requestId = UUID()

        let message = CompanionMessage.protocolError(
            .init(
                protocolVersion: 1,
                id: uuid,
                requestId: requestId,
                code: .duplicateRequestID,
                message: "seen before"
            )
        )

        let encoded = try CompanionMessageCodec.encodeBody(message)
        let decoded = try CompanionMessageCodec.decodeBody(encoded)
        #expect(decoded == message)
    }

    // MARK: - Decoding errors

    @Test("Decoder rejects non-JSON bodies")
    func decoderRejectsNonJSON() {
        let body = Data("not json".utf8)
        #expect(throws: CompanionProtocolError.self) {
            try CompanionMessageCodec.decodeBody(body)
        }
    }

    @Test("Decoder rejects JSON that is not an object")
    func decoderRejectsNonObject() {
        let body = Data("[1,2,3]".utf8)
        #expect(throws: CompanionProtocolError.self) {
            try CompanionMessageCodec.decodeBody(body)
        }
    }

    @Test("Decoder rejects an unknown message type")
    func decoderRejectsUnknownType() {
        let body = Data(#"{"protocolVersion":1,"type":"unknown","id":"x"}"#.utf8)
        do {
            _ = try CompanionMessageCodec.decodeBody(body)
            Issue.record("expected unsupportedType")
        } catch let error as CompanionProtocolError {
            if case .unsupportedType(let type) = error {
                #expect(type == "unknown")
            } else {
                Issue.record("unexpected error: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Decoder rejects missing required fields")
    func decoderRejectsMissingFields() {
        let body = Data(#"{"protocolVersion":1,"type":"apply_theme","id":"x"}"#.utf8)
        #expect(throws: CompanionProtocolError.self) {
            try CompanionMessageCodec.decodeBody(body)
        }
    }

    @Test(
        "Decoder does not enforce protocol version — session applies policy"
    )
    func decoderIgnoresProtocolVersion() throws {
        let body = Data(
            #"{"protocolVersion":99,"type":"register_ack","id":"11111111-2222-3333-4444-555555555555","sessionId":"s"}"#
                .utf8
        )
        let decoded = try CompanionMessageCodec.decodeBody(body)
        #expect(decoded.protocolVersion == 99)
    }

    @Test("Decoder rejects invalid UUIDs in the id field")
    func decoderRejectsInvalidUUID() {
        let body = Data(#"{"protocolVersion":1,"type":"register_ack","id":"not-a-uuid","sessionId":"s"}"#.utf8)
        #expect(throws: CompanionProtocolError.self) {
            try CompanionMessageCodec.decodeBody(body)
        }
    }

    // MARK: - Wire format compatibility

    @Test("Register decodes canonical JSON with all documented fields")
    func decoderAcceptsCanonicalRegister() throws {
        let body = Data(
            #"""
            {
              "protocolVersion": 1,
              "type": "register",
              "id": "11111111-2222-3333-4444-555555555555",
              "launchNonce": "nonce-abc",
              "extensionVersion": "0.1.0",
              "vscode": {
                "edition": "vscode",
                "version": "1.94.0",
                "profileName": "Default",
                "profileId": "profile-1",
                "machineId": "machine-1",
                "sessionId": "session-1",
                "processId": 12345,
                "windowId": "window-1"
              },
              "capabilities": ["colorTheme"],
              "currentSettings": {"workbench.colorTheme": "Old"}
            }
            """#.utf8
        )
        let decoded = try CompanionMessageCodec.decodeBody(body)
        guard case .register(let register) = decoded else {
            Issue.record("expected register message")
            return
        }
        #expect(register.launchNonce == "nonce-abc")
        #expect(register.extensionVersion == "0.1.0")
        #expect(register.capabilities == ["colorTheme"])
        #expect(register.vscode.edition == "vscode")
        #expect(register.vscode.processId == 12_345)
        #expect(register.currentSettings["workbench.colorTheme"] == "Old")
    }

    @Test("Apply theme ack encodes the documented status strings")
    func applyThemeAckStatusStrings() throws {
        for (status, expected) in [
            (CompanionApplyThemeStatus.applied, "applied"),
            (.overridden, "overridden"),
            (.unsupportedTheme, "unsupported_theme"),
            (.failed, "failed"),
        ] {
            let message = CompanionMessage.applyThemeAck(
                .init(
                    protocolVersion: 1,
                    id: UUID(),
                    status: status,
                    effectiveSetting: nil,
                    requestedSetting: "X",
                    overrides: [],
                    failure: status == .failed ? .init(code: "c", message: "m") : nil
                )
            )
            let encoded = try CompanionMessageCodec.encodeBody(message)
            let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            #expect(object?["status"] as? String == expected)
        }
    }
}
