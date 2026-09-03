import Foundation

// MARK: - Public constants

/// The protocol version currently spoken by this build. Both sides of the
/// companion socket must agree on the version before exchanging any
/// application messages; see
/// `docs/architecture/vscode-companion-protocol.md` for the wire format.
public enum CompanionProtocol {
    /// The current protocol version implemented by the server and pinned
    /// companion extension.
    public static let currentVersion: Int = 1

    /// The versions this server can speak. Callers use this range to
    /// negotiate against an extension's advertised version.
    public static let supportedVersions: ClosedRange<Int> = 1...1
}

// MARK: - Frame codec

/// Length-prefixed JSON framing described in the wire protocol document.
///
/// A frame is a big-endian 32-bit unsigned length prefix followed by a
/// JSON body of exactly that length. `CompanionFrame.encode(body:)`
/// produces the framed bytes for a single body. `CompanionFrameDecoder`
/// is the streaming counterpart: it buffers arbitrary chunks of bytes
/// and hands back complete bodies one at a time.
public enum CompanionFrame {
    /// Prefix `body` with its 32-bit big-endian length. The caller is
    /// responsible for ensuring `body` does not exceed
    /// ``CompanionFrameDecoder/maxBodySize``.
    public static func encode(body: Data) -> Data {
        var framed = Data(capacity: body.count + 4)
        let length = UInt32(body.count)
        framed.append(UInt8((length >> 24) & 0xFF))
        framed.append(UInt8((length >> 16) & 0xFF))
        framed.append(UInt8((length >> 8) & 0xFF))
        framed.append(UInt8(length & 0xFF))
        framed.append(body)
        return framed
    }
}

/// A streaming frame decoder that consumes bytes into an internal buffer
/// and produces complete JSON bodies when they become available. The
/// caller feeds `append(_:)` with whatever chunk arrived from the socket
/// and then drains the buffer with `nextFrame()` until it returns `nil`.
public struct CompanionFrameDecoder {
    /// The largest JSON body the decoder will accept. A frame that
    /// announces a longer body is rejected before any bytes of it are
    /// buffered.
    public static let maxBodySize: Int = 65_536

    private var buffer: Data

    public init() {
        self.buffer = Data()
    }

    /// Append a chunk of bytes just read from the socket. The decoder
    /// retains an internal buffer between calls so partial frames are
    /// preserved across reads.
    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// Return the next complete JSON body from the buffer, or `nil` if
    /// more bytes are required.
    public mutating func nextFrame() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).withUnsafeBytes { raw -> UInt32 in
            var value: UInt32 = 0
            for byte in raw { value = (value << 8) | UInt32(byte) }
            return value
        }
        let body = Int(length)
        guard body <= Self.maxBodySize else {
            throw CompanionProtocolError.bodyTooLarge(body)
        }
        guard buffer.count >= 4 + body else { return nil }
        let frame = buffer.subdata(in: 4..<(4 + body))
        buffer.removeSubrange(0..<(4 + body))
        return frame
    }
}

// MARK: - Protocol errors

/// Errors surfaced by the frame decoder and the message codec. These are
/// the reasons the socket layer sends `protocol_error` messages back to
/// a peer, but the codec itself only reports the classification: turning
/// them into wire messages is the caller's responsibility.
public enum CompanionProtocolError: Error, Equatable {
    case bodyTooLarge(Int)
    case malformedJSON
    case notObject
    case missingField(String)
    case unsupportedType(String)
    case unsupportedProtocolVersion(Int)
    case invalidUUID(String)
    case invalidEnum(field: String, value: String)
    case invalidField(String)

    /// The wire-level `protocol_error.code` that best classifies this
    /// error when the session turns it into an outgoing message.
    public var wireCode: CompanionProtocolErrorCode {
        switch self {
        case .unsupportedProtocolVersion:
            return .unsupportedProtocolVersion
        case .unsupportedType:
            return .unsupportedType
        case .missingField:
            return .missingRequiredField
        case .bodyTooLarge, .malformedJSON, .notObject, .invalidUUID,
            .invalidEnum, .invalidField:
            return .malformedFrame
        }
    }

    /// A human-readable description of the error, intended to be sent
    /// as `protocol_error.message`. Callers should not rely on the
    /// exact wording; it is meant for diagnostics only.
    public var wireMessage: String {
        switch self {
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

// MARK: - Messages

/// The identity a companion instance advertises during registration.
/// Callers should treat every field as opaque: the values are used only
/// for surface in receipts, override reporting, and diagnostics.
public struct CompanionVSCodeIdentity: Codable, Equatable, Sendable {
    public let edition: String
    public let version: String
    public let profileName: String
    public let profileId: String
    public let machineId: String
    public let sessionId: String
    public let processId: Int
    public let windowId: String

    public init(
        edition: String,
        version: String,
        profileName: String,
        profileId: String,
        machineId: String,
        sessionId: String,
        processId: Int,
        windowId: String
    ) {
        self.edition = edition
        self.version = version
        self.profileName = profileName
        self.profileId = profileId
        self.machineId = machineId
        self.sessionId = sessionId
        self.processId = processId
        self.windowId = windowId
    }
}

public struct CompanionRegisterMessage: Equatable, Sendable {
    public let protocolVersion: Int
    public let id: UUID
    public let launchNonce: String
    public let extensionVersion: String
    public let vscode: CompanionVSCodeIdentity
    public let capabilities: [String]
    public let currentSettings: [String: String]

    public init(
        protocolVersion: Int,
        id: UUID,
        launchNonce: String,
        extensionVersion: String,
        vscode: CompanionVSCodeIdentity,
        capabilities: [String],
        currentSettings: [String: String]
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.launchNonce = launchNonce
        self.extensionVersion = extensionVersion
        self.vscode = vscode
        self.capabilities = capabilities
        self.currentSettings = currentSettings
    }
}

public struct CompanionRegisterAckMessage: Equatable, Sendable {
    public let protocolVersion: Int
    public let id: UUID
    public let sessionId: String

    public init(protocolVersion: Int, id: UUID, sessionId: String) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.sessionId = sessionId
    }
}

public enum CompanionRegisterRejectionReason: String, Codable, Equatable, Sendable {
    case unsupportedProtocol = "unsupported_protocol"
    case invalidNonce = "invalid_nonce"
    case duplicateRegistration = "duplicate_registration"
    case missingCapability = "missing_capability"
    case unauthenticatedPeer = "unauthenticated_peer"
}

public struct CompanionRegisterRejectedMessage: Equatable, Sendable {
    public let protocolVersion: Int
    public let id: UUID
    public let reason: CompanionRegisterRejectionReason

    public init(protocolVersion: Int, id: UUID, reason: CompanionRegisterRejectionReason) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.reason = reason
    }
}

public enum CompanionApplyTarget: String, Codable, Equatable, Sendable {
    case global
}

public enum VSCodeCompanionRequestError: Error, Equatable, Sendable {
    case timeout
    case disconnected
    case staleRequest
    case duplicateRequest
    case unsupportedProtocol
    case malformedAcknowledgement
    case targetUnavailable
    case notRunning
}

public struct VSCodeCompanionThemeRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let themeName: String?
    public let expectedSetting: String?
    public let target: CompanionApplyTarget

    public init(
        protocolVersion: Int,
        themeName: String?,
        expectedSetting: String?,
        target: CompanionApplyTarget
    ) {
        self.protocolVersion = protocolVersion
        self.themeName = themeName
        self.expectedSetting = expectedSetting
        self.target = target
    }
}

public struct CompanionThemeInspection: Codable, Equatable, Sendable {
    public let configuredSetting: String?
    public let effectiveSetting: String?
    public let overrides: [CompanionOverride]

    public init(
        configuredSetting: String?,
        effectiveSetting: String?,
        overrides: [CompanionOverride]
    ) {
        self.configuredSetting = configuredSetting
        self.effectiveSetting = effectiveSetting
        self.overrides = overrides
    }
}

public struct CompanionInspectThemeMessage: Equatable, Sendable {
    public let protocolVersion: Int
    public let id: UUID
    public let sessionId: String

    public init(protocolVersion: Int, id: UUID, sessionId: String) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.sessionId = sessionId
    }
}

public struct CompanionApplyThemeMessage: Equatable, Sendable {
    public let protocolVersion: Int
    public let id: UUID
    public let sessionId: String
    /// The value to write to `workbench.colorTheme`, or `nil` to remove the
    /// global setting and return to VS Code's default.
    public let themeName: String?
    /// The global setting observed while preparing the request. The companion
    /// refuses the write if the setting has changed since then.
    public let expectedSetting: String?
    public let target: CompanionApplyTarget

    public init(
        protocolVersion: Int,
        id: UUID,
        sessionId: String,
        themeName: String?,
        expectedSetting: String? = nil,
        target: CompanionApplyTarget
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.sessionId = sessionId
        self.themeName = themeName
        self.expectedSetting = expectedSetting
        self.target = target
    }
}

public enum CompanionApplyThemeStatus: String, Codable, Equatable, Sendable {
    case applied
    case overridden
    case unsupportedTheme = "unsupported_theme"
    case conflicted
    case failed
}

public enum CompanionOverrideScope: String, Codable, Equatable, Sendable {
    case workspace
    case workspaceFolder = "workspaceFolder"
    case remote
}

public struct CompanionOverride: Codable, Equatable, Sendable {
    public let scope: CompanionOverrideScope
    public let folder: String?
    public let value: String

    public init(scope: CompanionOverrideScope, folder: String?, value: String) {
        self.scope = scope
        self.folder = folder
        self.value = value
    }
}

public struct CompanionApplyFailure: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct CompanionInspectThemeAckMessage: Equatable, Sendable {
    public let protocolVersion: Int
    public let id: UUID
    public let configuredSetting: String?
    public let effectiveSetting: String?
    public let overrides: [CompanionOverride]

    public init(
        protocolVersion: Int,
        id: UUID,
        configuredSetting: String?,
        effectiveSetting: String?,
        overrides: [CompanionOverride]
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.configuredSetting = configuredSetting
        self.effectiveSetting = effectiveSetting
        self.overrides = overrides
    }
}

public struct CompanionApplyThemeAckMessage: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let id: UUID
    public let status: CompanionApplyThemeStatus
    public let effectiveSetting: String?
    public let requestedSetting: String?
    public let previousSetting: String?
    public let configuredSetting: String?
    public let overrides: [CompanionOverride]
    public let failure: CompanionApplyFailure?

    public init(
        protocolVersion: Int,
        id: UUID,
        status: CompanionApplyThemeStatus,
        effectiveSetting: String?,
        requestedSetting: String?,
        previousSetting: String? = nil,
        configuredSetting: String? = nil,
        overrides: [CompanionOverride],
        failure: CompanionApplyFailure?
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.status = status
        self.effectiveSetting = effectiveSetting
        self.requestedSetting = requestedSetting
        self.previousSetting = previousSetting
        self.configuredSetting = configuredSetting
        self.overrides = overrides
        self.failure = failure
    }
}

public enum CompanionProtocolErrorCode: String, Codable, Equatable, Sendable {
    case malformedFrame = "malformed_frame"
    case unsupportedType = "unsupported_type"
    case unsupportedProtocolVersion = "unsupported_protocol_version"
    case duplicateRequestID = "duplicate_request_id"
    case unexpectedMessage = "unexpected_message"
    case missingRequiredField = "missing_required_field"
    case notRegistered = "not_registered"
}

public struct CompanionProtocolErrorMessage: Equatable, Sendable {
    public let protocolVersion: Int
    public let id: UUID
    public let requestId: UUID?
    public let code: CompanionProtocolErrorCode
    public let message: String

    public init(
        protocolVersion: Int,
        id: UUID,
        requestId: UUID?,
        code: CompanionProtocolErrorCode,
        message: String
    ) {
        self.protocolVersion = protocolVersion
        self.id = id
        self.requestId = requestId
        self.code = code
        self.message = message
    }
}

public enum CompanionMessage: Equatable, Sendable {
    case register(CompanionRegisterMessage)
    case registerAck(CompanionRegisterAckMessage)
    case registerRejected(CompanionRegisterRejectedMessage)
    case inspectTheme(CompanionInspectThemeMessage)
    case inspectThemeAck(CompanionInspectThemeAckMessage)
    case applyTheme(CompanionApplyThemeMessage)
    case applyThemeAck(CompanionApplyThemeAckMessage)
    case protocolError(CompanionProtocolErrorMessage)

    public var protocolVersion: Int {
        switch self {
        case .register(let m): return m.protocolVersion
        case .registerAck(let m): return m.protocolVersion
        case .registerRejected(let m): return m.protocolVersion
        case .inspectTheme(let m): return m.protocolVersion
        case .inspectThemeAck(let m): return m.protocolVersion
        case .applyTheme(let m): return m.protocolVersion
        case .applyThemeAck(let m): return m.protocolVersion
        case .protocolError(let m): return m.protocolVersion
        }
    }

    public var id: UUID {
        switch self {
        case .register(let m): return m.id
        case .registerAck(let m): return m.id
        case .registerRejected(let m): return m.id
        case .inspectTheme(let m): return m.id
        case .inspectThemeAck(let m): return m.id
        case .applyTheme(let m): return m.id
        case .applyThemeAck(let m): return m.id
        case .protocolError(let m): return m.id
        }
    }
}

// MARK: - Message codec

/// JSON codec for wire messages. The codec produces and consumes the
/// body of a companion frame; the framing itself is handled by
/// ``CompanionFrame`` and ``CompanionFrameDecoder``.
///
/// Encoding is total: every constructor of ``CompanionMessage`` produces
/// a valid JSON body. Decoding validates:
///
/// - that the top-level value is a JSON object,
/// - that `protocolVersion` is within
///   ``CompanionProtocol/supportedVersions``,
/// - that the `type` field is a known message type,
/// - that `id` (and `requestId` when present) parse as UUIDs, and
/// - that each type's required fields are present and well typed.
public enum CompanionMessageCodec {
    /// Serialize `message` into the JSON body of a companion frame.
    public static func encodeBody(_ message: CompanionMessage) throws -> Data {
        let object = encodeObject(message)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Parse the JSON body of a companion frame into a typed message.
    /// Throws ``CompanionProtocolError`` for anything the wire protocol
    /// classifies as a protocol error.
    public static func decodeBody(_ body: Data) throws -> CompanionMessage {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(
                with: body, options: [.fragmentsAllowed])
        } catch {
            throw CompanionProtocolError.malformedJSON
        }
        guard let object = raw as? [String: Any] else {
            throw CompanionProtocolError.notObject
        }
        let reader = ObjectReader(object)

        let protocolVersion = try reader.requireInt("protocolVersion")
        let type = try reader.requireString("type")

        // The message type gates the rest of the decode: an unknown type
        // cannot be dispatched even if `id` is well formed, so we
        // validate it before demanding a UUID.
        switch type {
        case "register", "register_ack", "register_rejected",
            "inspect_theme", "inspect_theme_ack", "apply_theme", "apply_theme_ack",
            "protocol_error":
            break
        default:
            throw CompanionProtocolError.unsupportedType(type)
        }

        let id = try reader.requireUUID("id")

        switch type {
        case "register":
            return .register(try decodeRegister(reader, protocolVersion: protocolVersion, id: id))
        case "register_ack":
            return .registerAck(
                CompanionRegisterAckMessage(
                    protocolVersion: protocolVersion,
                    id: id,
                    sessionId: try reader.requireString("sessionId")
                )
            )
        case "register_rejected":
            let reasonString = try reader.requireString("reason")
            guard let reason = CompanionRegisterRejectionReason(rawValue: reasonString) else {
                throw CompanionProtocolError.invalidEnum(field: "reason", value: reasonString)
            }
            return .registerRejected(
                CompanionRegisterRejectedMessage(
                    protocolVersion: protocolVersion, id: id, reason: reason
                )
            )
        case "inspect_theme":
            return .inspectTheme(
                CompanionInspectThemeMessage(
                    protocolVersion: protocolVersion,
                    id: id,
                    sessionId: try reader.requireString("sessionId")
                )
            )
        case "inspect_theme_ack":
            return .inspectThemeAck(
                try decodeInspectAck(reader, protocolVersion: protocolVersion, id: id)
            )
        case "apply_theme":
            let targetString = try reader.requireString("target")
            guard let target = CompanionApplyTarget(rawValue: targetString) else {
                throw CompanionProtocolError.invalidEnum(field: "target", value: targetString)
            }
            return .applyTheme(
                CompanionApplyThemeMessage(
                    protocolVersion: protocolVersion,
                    id: id,
                    sessionId: try reader.requireString("sessionId"),
                    themeName: try reader.requireNullableString("themeName"),
                    expectedSetting: try reader.requireNullableString("expectedSetting"),
                    target: target
                )
            )
        case "apply_theme_ack":
            return .applyThemeAck(
                try decodeApplyAck(reader, protocolVersion: protocolVersion, id: id)
            )
        case "protocol_error":
            let codeString = try reader.requireString("code")
            guard let code = CompanionProtocolErrorCode(rawValue: codeString) else {
                throw CompanionProtocolError.invalidEnum(field: "code", value: codeString)
            }
            let requestId: UUID?
            if let raw = reader.optionalString("requestId") {
                guard let parsed = UUID(uuidString: raw) else {
                    throw CompanionProtocolError.invalidUUID(raw)
                }
                requestId = parsed
            } else {
                requestId = nil
            }
            return .protocolError(
                CompanionProtocolErrorMessage(
                    protocolVersion: protocolVersion,
                    id: id,
                    requestId: requestId,
                    code: code,
                    message: try reader.requireString("message")
                )
            )
        default:
            // Unreachable: guarded above.
            throw CompanionProtocolError.unsupportedType(type)
        }
    }

    // MARK: - Private encoding

    private static func encodeObject(_ message: CompanionMessage) -> [String: Any] {
        switch message {
        case .register(let m):
            return [
                "protocolVersion": m.protocolVersion,
                "type": "register",
                "id": m.id.uuidString,
                "launchNonce": m.launchNonce,
                "extensionVersion": m.extensionVersion,
                "vscode": [
                    "edition": m.vscode.edition,
                    "version": m.vscode.version,
                    "profileName": m.vscode.profileName,
                    "profileId": m.vscode.profileId,
                    "machineId": m.vscode.machineId,
                    "sessionId": m.vscode.sessionId,
                    "processId": m.vscode.processId,
                    "windowId": m.vscode.windowId,
                ],
                "capabilities": m.capabilities,
                "currentSettings": m.currentSettings,
            ]
        case .registerAck(let m):
            return [
                "protocolVersion": m.protocolVersion,
                "type": "register_ack",
                "id": m.id.uuidString,
                "sessionId": m.sessionId,
            ]
        case .registerRejected(let m):
            return [
                "protocolVersion": m.protocolVersion,
                "type": "register_rejected",
                "id": m.id.uuidString,
                "reason": m.reason.rawValue,
            ]
        case .inspectTheme(let m):
            return [
                "protocolVersion": m.protocolVersion,
                "type": "inspect_theme",
                "id": m.id.uuidString,
                "sessionId": m.sessionId,
            ]
        case .inspectThemeAck(let m):
            var object: [String: Any] = [
                "protocolVersion": m.protocolVersion,
                "type": "inspect_theme_ack",
                "id": m.id.uuidString,
                "overrides": encodeOverrides(m.overrides),
            ]
            if let configured = m.configuredSetting { object["configuredSetting"] = configured }
            if let effective = m.effectiveSetting { object["effectiveSetting"] = effective }
            return object
        case .applyTheme(let m):
            return [
                "protocolVersion": m.protocolVersion,
                "type": "apply_theme",
                "id": m.id.uuidString,
                "sessionId": m.sessionId,
                "themeName": m.themeName as Any? ?? NSNull(),
                "expectedSetting": m.expectedSetting as Any? ?? NSNull(),
                "target": m.target.rawValue,
            ]
        case .applyThemeAck(let m):
            var object: [String: Any] = [
                "protocolVersion": m.protocolVersion,
                "type": "apply_theme_ack",
                "id": m.id.uuidString,
                "status": m.status.rawValue,
                "requestedSetting": m.requestedSetting as Any? ?? NSNull(),
                "overrides": encodeOverrides(m.overrides),
            ]
            if let previous = m.previousSetting { object["previousSetting"] = previous }
            if let configured = m.configuredSetting { object["configuredSetting"] = configured }
            if let effective = m.effectiveSetting { object["effectiveSetting"] = effective }
            if let failure = m.failure {
                object["failure"] = [
                    "code": failure.code,
                    "message": failure.message,
                ]
            }
            return object
        case .protocolError(let m):
            var object: [String: Any] = [
                "protocolVersion": m.protocolVersion,
                "type": "protocol_error",
                "id": m.id.uuidString,
                "code": m.code.rawValue,
                "message": m.message,
            ]
            if let requestId = m.requestId {
                object["requestId"] = requestId.uuidString
            }
            return object
        }
    }

    // MARK: - Private decoding helpers

    private static func decodeRegister(
        _ reader: ObjectReader, protocolVersion: Int, id: UUID
    ) throws -> CompanionRegisterMessage {
        let launchNonce = try reader.requireString("launchNonce")
        let extensionVersion = try reader.requireString("extensionVersion")
        let vscodeReader = try reader.requireObject("vscode")
        let vscode = CompanionVSCodeIdentity(
            edition: try vscodeReader.requireString("edition"),
            version: try vscodeReader.requireString("version"),
            profileName: try vscodeReader.requireString("profileName"),
            profileId: try vscodeReader.requireString("profileId"),
            machineId: try vscodeReader.requireString("machineId"),
            sessionId: try vscodeReader.requireString("sessionId"),
            processId: try vscodeReader.requireInt("processId"),
            windowId: try vscodeReader.requireString("windowId")
        )
        let capabilities = try reader.requireStringArray("capabilities")
        let currentSettings = try reader.requireStringDictionary("currentSettings")
        return CompanionRegisterMessage(
            protocolVersion: protocolVersion,
            id: id,
            launchNonce: launchNonce,
            extensionVersion: extensionVersion,
            vscode: vscode,
            capabilities: capabilities,
            currentSettings: currentSettings
        )
    }

    private static func decodeInspectAck(
        _ reader: ObjectReader, protocolVersion: Int, id: UUID
    ) throws -> CompanionInspectThemeAckMessage {
        CompanionInspectThemeAckMessage(
            protocolVersion: protocolVersion,
            id: id,
            configuredSetting: try reader.optionalNullableString("configuredSetting"),
            effectiveSetting: try reader.optionalNullableString("effectiveSetting"),
            overrides: try decodeOverrides(reader)
        )
    }

    private static func decodeApplyAck(
        _ reader: ObjectReader, protocolVersion: Int, id: UUID
    ) throws -> CompanionApplyThemeAckMessage {
        let statusString = try reader.requireString("status")
        guard let status = CompanionApplyThemeStatus(rawValue: statusString) else {
            throw CompanionProtocolError.invalidEnum(field: "status", value: statusString)
        }
        let requestedSetting = try reader.requireNullableString("requestedSetting")
        let previousSetting = try reader.optionalNullableString("previousSetting")
        let configuredSetting = try reader.optionalNullableString("configuredSetting")
        let effectiveSetting = try reader.optionalNullableString("effectiveSetting")
        let overrides = try decodeOverrides(reader)

        let failure: CompanionApplyFailure?
        if reader.contains("failure") {
            let failureObject = try reader.requireObject("failure")
            failure = CompanionApplyFailure(
                code: try failureObject.requireString("code"),
                message: try failureObject.requireString("message")
            )
        } else {
            failure = nil
        }
        if status == .failed, failure == nil {
            throw CompanionProtocolError.missingField("failure")
        }
        if status != .failed, failure != nil {
            throw CompanionProtocolError.invalidField("failure")
        }

        return CompanionApplyThemeAckMessage(
            protocolVersion: protocolVersion,
            id: id,
            status: status,
            effectiveSetting: effectiveSetting,
            requestedSetting: requestedSetting,
            previousSetting: previousSetting,
            configuredSetting: configuredSetting,
            overrides: overrides,
            failure: failure
        )
    }

    private static func decodeOverrides(_ reader: ObjectReader) throws -> [CompanionOverride] {
        try reader.requireArray("overrides").map { entry in
            guard let entryObject = entry as? [String: Any] else {
                throw CompanionProtocolError.invalidField("overrides")
            }
            let entryReader = ObjectReader(entryObject)
            let scopeString = try entryReader.requireString("scope")
            guard let scope = CompanionOverrideScope(rawValue: scopeString) else {
                throw CompanionProtocolError.invalidEnum(field: "scope", value: scopeString)
            }
            return CompanionOverride(
                scope: scope,
                folder: try entryReader.optionalNullableString("folder"),
                value: try entryReader.requireString("value")
            )
        }
    }

    private static func encodeOverrides(_ overrides: [CompanionOverride]) -> [[String: Any]] {
        overrides.map { override in
            var object: [String: Any] = [
                "scope": override.scope.rawValue,
                "value": override.value,
            ]
            if let folder = override.folder { object["folder"] = folder }
            return object
        }
    }
}

// MARK: - ObjectReader

/// Small helper around `[String: Any]` that produces
/// `CompanionProtocolError` when a required field is missing or
/// mis-typed. Kept private to the codec so callers see only structured
/// errors.
private struct ObjectReader {
    let object: [String: Any]

    init(_ object: [String: Any]) { self.object = object }

    func contains(_ key: String) -> Bool {
        object[key] != nil
    }

    func requireString(_ key: String) throws -> String {
        guard let raw = object[key] else {
            throw CompanionProtocolError.missingField(key)
        }
        guard let value = raw as? String else {
            throw CompanionProtocolError.invalidField(key)
        }
        return value
    }

    func requireNullableString(_ key: String) throws -> String? {
        guard let raw = object[key] else {
            throw CompanionProtocolError.missingField(key)
        }
        if raw is NSNull { return nil }
        guard let value = raw as? String else {
            throw CompanionProtocolError.invalidField(key)
        }
        return value
    }

    func requireInt(_ key: String) throws -> Int {
        guard let raw = object[key] else {
            throw CompanionProtocolError.missingField(key)
        }
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        throw CompanionProtocolError.invalidField(key)
    }

    func requireUUID(_ key: String) throws -> UUID {
        let raw = try requireString(key)
        guard let uuid = UUID(uuidString: raw) else {
            throw CompanionProtocolError.invalidUUID(raw)
        }
        return uuid
    }

    func requireObject(_ key: String) throws -> ObjectReader {
        guard let raw = object[key] else {
            throw CompanionProtocolError.missingField(key)
        }
        guard let dict = raw as? [String: Any] else {
            throw CompanionProtocolError.invalidField(key)
        }
        return ObjectReader(dict)
    }

    func requireStringArray(_ key: String) throws -> [String] {
        guard let raw = object[key] else {
            throw CompanionProtocolError.missingField(key)
        }
        guard let array = raw as? [String] else {
            throw CompanionProtocolError.invalidField(key)
        }
        return array
    }

    func requireStringDictionary(_ key: String) throws -> [String: String] {
        guard let raw = object[key] else {
            throw CompanionProtocolError.missingField(key)
        }
        guard let dict = raw as? [String: String] else {
            throw CompanionProtocolError.invalidField(key)
        }
        return dict
    }

    func optionalString(_ key: String) -> String? {
        object[key] as? String
    }

    func optionalNullableString(_ key: String) throws -> String? {
        guard let raw = object[key] else { return nil }
        if raw is NSNull { return nil }
        guard let value = raw as? String else {
            throw CompanionProtocolError.invalidField(key)
        }
        return value
    }

    func requireArray(_ key: String) throws -> [Any] {
        guard let raw = object[key] else {
            throw CompanionProtocolError.missingField(key)
        }
        guard let array = raw as? [Any] else {
            throw CompanionProtocolError.invalidField(key)
        }
        return array
    }

    func optionalArray(_ key: String) -> [Any]? {
        object[key] as? [Any]
    }

    func optionalObject(_ key: String) -> ObjectReader? {
        (object[key] as? [String: Any]).map(ObjectReader.init)
    }
}
