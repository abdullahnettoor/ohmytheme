import Darwin
import Dispatch
import Foundation
import Testing

@testable import PlatformClients

@Suite("VS Code companion socket server (integration)")
struct VSCodeCompanionSocketServerTests {

    // MARK: - Fixture

    /// Sets up a private temporary directory and a running server bound
    /// to a socket inside it. `tearDown()` stops the server and removes
    /// the directory.
    final class Fixture {
        let base: URL
        let root: URL
        let socketRoot: URL
        let server: CompanionSocketServer
        let paths: CompanionSocketPaths
        let launchID: String
        let launchNonce: String

        init(
            launchID: String = UUID().uuidString,
            launchNonce: String = UUID().uuidString,
            expectedPeerEUID: uid_t = geteuid(),
            registerTimeout: TimeInterval = 5,
            requestTimeout: TimeInterval = 5
        ) throws {
            // Keep the root path short: `sun_path` is capped at 104 bytes.
            let short = "omt-\(UUID().uuidString.prefix(8))"
            self.base = URL(fileURLWithPath: "/tmp/\(short)", isDirectory: true)
            self.root = base.appendingPathComponent("rendezvous", isDirectory: true)
            self.socketRoot = base.appendingPathComponent("socket", isDirectory: true)
            self.launchID = launchID
            self.launchNonce = launchNonce
            self.paths = CompanionSocketPaths(
                root: root,
                socketRoot: socketRoot,
                launchID: launchID
            )
            self.server = CompanionSocketServer(
                configuration: CompanionSocketServerConfiguration(
                    paths: paths,
                    launchID: launchID,
                    launchNonce: launchNonce,
                    registerTimeout: registerTimeout,
                    requestTimeout: requestTimeout,
                    expectedPeerEUID: expectedPeerEUID
                )
            )
        }

        deinit {
            server.stop()
            try? FileManager.default.removeItem(at: base)
        }
    }

    /// Simple synchronous test client: opens the Unix-domain socket,
    /// speaks the framed protocol, and closes.
    final class TestClient {
        private var fd: Int32
        private var decoder = CompanionFrameDecoder()

        init(socketPath: String) throws {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw NSError(
                    domain: "test.client", code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "socket() failed"]
                )
            }
            var nosigpipe: Int32 = 1
            _ = setsockopt(
                fd, SOL_SOCKET, SO_NOSIGPIPE,
                &nosigpipe, socklen_t(MemoryLayout<Int32>.size)
            )
            // Non-blocking so `receive()` can honor its timeout.
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            _ = withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
                rawPtr.withMemoryRebound(to: CChar.self, capacity: 104) { chars in
                    socketPath.withCString { source in
                        strncpy(chars, source, 103)
                    }
                }
            }
            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &addr) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, addrLen)
                }
            }
            guard result == 0 else {
                Darwin.close(fd)
                throw NSError(
                    domain: "test.client", code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "connect() failed"]
                )
            }
            self.fd = fd
        }

        deinit { close() }

        func close() {
            guard fd >= 0 else { return }
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }

        func send(_ message: CompanionMessage) throws {
            let body = try CompanionMessageCodec.encodeBody(message)
            let framed = CompanionFrame.encode(body: body)
            try framed.withUnsafeBytes { raw in
                var written = 0
                while written < raw.count {
                    let base = raw.baseAddress!.advanced(by: written)
                    let n = Darwin.write(fd, base, raw.count - written)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw NSError(
                            domain: "test.client", code: Int(errno),
                            userInfo: [NSLocalizedDescriptionKey: "write() failed"]
                        )
                    }
                    written += n
                }
            }
        }

        /// Send a raw frame body without going through the codec. Used
        /// to inject malformed messages.
        func sendRaw(_ body: Data) throws {
            let framed = CompanionFrame.encode(body: body)
            _ = try framed.withUnsafeBytes { raw -> Int in
                var written = 0
                while written < raw.count {
                    let base = raw.baseAddress!.advanced(by: written)
                    let n = Darwin.write(fd, base, raw.count - written)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw NSError(
                            domain: "test.client", code: Int(errno),
                            userInfo: [NSLocalizedDescriptionKey: "write() failed"]
                        )
                    }
                    written += n
                }
                return written
            }
        }

        func receive(timeout: TimeInterval = 2) throws -> CompanionMessage? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                var frameBody: Data? = nil
                do {
                    frameBody = try decoder.nextFrame()
                } catch {
                    return nil
                }
                if let body = frameBody {
                    return try CompanionMessageCodec.decodeBody(body)
                }
                var buffer = [UInt8](repeating: 0, count: 4096)
                let n = buffer.withUnsafeMutableBufferPointer {
                    Darwin.read(fd, $0.baseAddress, $0.count)
                }
                if n > 0 {
                    decoder.append(Data(bytes: buffer, count: n))
                    continue
                }
                if n == 0 { return nil }  // peer closed
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                return nil
            }
            return nil
        }
    }

    // MARK: - Basic lifecycle

    @Test("The production socket path fits the macOS Unix-domain limit")
    func productionSocketPathFitsMacOSLimit() throws {
        let paths = try CompanionSocketPaths.production(
            launchID: "12345678-1234-1234-1234-123456789012"
        )

        #expect(paths.socketFile.path.utf8.count <= 103)
    }

    @Test("A symlink cannot redirect the private socket root")
    func rejectsSymlinkedSocketRoot() throws {
        let base = URL(fileURLWithPath: "/tmp/omt-symlink-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let victim = base.appendingPathComponent("victim", isDirectory: true)
        try FileManager.default.createDirectory(
            at: victim,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        let socketRoot = base.appendingPathComponent("socket", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: socketRoot, withDestinationURL: victim)
        let launchID = "12345678-1234-1234-1234-123456789012"
        let paths = CompanionSocketPaths(
            root: base.appendingPathComponent("rendezvous", isDirectory: true),
            socketRoot: socketRoot,
            launchID: launchID
        )
        let server = CompanionSocketServer(
            configuration: CompanionSocketServerConfiguration(
                paths: paths,
                launchID: launchID,
                launchNonce: "nonce"
            )
        )
        defer { server.stop() }
        var rejected = false

        do {
            try server.start()
        } catch {
            rejected = true
        }

        #expect(rejected)
        let victimMode =
            try FileManager.default.attributesOfItem(atPath: victim.path)[
                .posixPermissions] as? NSNumber
        #expect(victimMode?.uint16Value == 0o755)
    }

    @Test("Starting the server creates the socket file with 0600 and the root dir with 0700")
    func startCreatesRestrictedFiles() throws {
        let fixture = try Fixture()
        try fixture.server.start()
        defer { fixture.server.stop() }

        // Wait briefly for the accept loop and rendezvous write to settle.
        Thread.sleep(forTimeInterval: 0.05)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: fixture.paths.socketFile.path))
        #expect(fm.fileExists(atPath: fixture.paths.rendezvousFile.path))

        let socketMode =
            try fm.attributesOfItem(atPath: fixture.paths.socketFile.path)[
                .posixPermissions] as? NSNumber
        #expect(socketMode?.uint16Value == 0o600)

        let rendezvousMode =
            try fm.attributesOfItem(atPath: fixture.paths.rendezvousFile.path)[
                .posixPermissions] as? NSNumber
        #expect(rendezvousMode?.uint16Value == 0o600)

        let rendezvousDirMode =
            try fm.attributesOfItem(atPath: fixture.paths.root.path)[
                .posixPermissions] as? NSNumber
        #expect(rendezvousDirMode?.uint16Value == 0o700)

        let socketDirMode =
            try fm.attributesOfItem(atPath: fixture.paths.socketRoot.path)[
                .posixPermissions] as? NSNumber
        #expect(socketDirMode?.uint16Value == 0o700)
    }

    @Test("Starting the server publishes the rendezvous file with the launch nonce")
    func startPublishesRendezvous() throws {
        let fixture = try Fixture(launchNonce: "nonce-1234")
        try fixture.server.start()
        defer { fixture.server.stop() }

        Thread.sleep(forTimeInterval: 0.05)
        let data = try Data(contentsOf: fixture.paths.rendezvousFile)
        let rendezvous = try JSONDecoder().decode(CompanionRendezvous.self, from: data)

        #expect(rendezvous.socketPath == fixture.paths.socketFile.path)
        #expect(rendezvous.launchId == fixture.launchID)
        #expect(rendezvous.launchNonce == "nonce-1234")
        #expect(rendezvous.protocolVersion == CompanionProtocol.currentVersion)
        #expect(!rendezvous.supportedProtocolVersions.isEmpty)
    }

    @Test("Stopping the server removes the socket file and rendezvous file")
    func stopRemovesFiles() throws {
        let fixture = try Fixture()
        try fixture.server.start()
        Thread.sleep(forTimeInterval: 0.05)

        fixture.server.stop()

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: fixture.paths.socketFile.path))
        #expect(!fm.fileExists(atPath: fixture.paths.rendezvousFile.path))
    }

    @Test("Starting the server twice reports alreadyRunning")
    func doubleStartFails() throws {
        let fixture = try Fixture()
        try fixture.server.start()
        defer { fixture.server.stop() }

        #expect(throws: CompanionSocketServerError.self) {
            try fixture.server.start()
        }
    }

    // MARK: - Handshake

    @Test("A well-formed register produces a register_ack")
    func registerHandshake() throws {
        let fixture = try Fixture(launchNonce: "n-1")
        try fixture.server.start()
        defer { fixture.server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let client = try TestClient(socketPath: fixture.paths.socketFile.path)
        let registerID = UUID()
        try client.send(
            .register(
                CompanionRegisterMessage(
                    protocolVersion: 1,
                    id: registerID,
                    launchNonce: "n-1",
                    extensionVersion: "0.1.0",
                    vscode: CompanionVSCodeIdentity(
                        edition: "vscode",
                        version: "1.94.0",
                        profileName: "Default",
                        profileId: "p",
                        machineId: "m",
                        sessionId: "s",
                        processId: 1,
                        windowId: "w"
                    ),
                    capabilities: ["colorTheme"],
                    currentSettings: [:]
                )
            )
        )

        guard case .registerAck(let ack) = try client.receive() else {
            Issue.record("expected register_ack")
            return
        }
        #expect(ack.id == registerID)
        #expect(!ack.sessionId.isEmpty)
    }

    @Test("The server exposes the registered edition, profile, and window identity")
    func exposesRegistrationIdentity() throws {
        let fixture = try Fixture(launchNonce: "identity-nonce")
        try fixture.server.start()
        defer { fixture.server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let identity = CompanionVSCodeIdentity(
            edition: "vscode",
            version: "1.95.2",
            profileName: "Default",
            profileId: "profile-default",
            machineId: "machine-1",
            sessionId: "window-session-1",
            processId: 42,
            windowId: "window-session-1"
        )
        let client = try TestClient(socketPath: fixture.paths.socketFile.path)
        try client.send(
            .register(
                CompanionRegisterMessage(
                    protocolVersion: 1,
                    id: UUID(),
                    launchNonce: "identity-nonce",
                    extensionVersion: "0.1.0",
                    vscode: identity,
                    capabilities: ["colorTheme"],
                    currentSettings: ["workbench.colorTheme": "Default Dark+"]
                )
            )
        )
        guard case .registerAck(let ack) = try client.receive() else {
            Issue.record("expected register_ack")
            return
        }

        let registration = try #require(fixture.server.registrations().first)
        #expect(registration.serverSessionID == ack.sessionId)
        #expect(registration.extensionVersion == "0.1.0")
        #expect(registration.vscode == identity)
        #expect(registration.currentSettings["workbench.colorTheme"] == "Default Dark+")
    }

    @Test("A register with a stale launch nonce is rejected and the connection is closed")
    func staleLaunchNonceRejected() throws {
        let fixture = try Fixture(launchNonce: "current")
        try fixture.server.start()
        defer { fixture.server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let client = try TestClient(socketPath: fixture.paths.socketFile.path)
        let registerID = UUID()
        try client.send(
            .register(
                CompanionRegisterMessage(
                    protocolVersion: 1,
                    id: registerID,
                    launchNonce: "stale",
                    extensionVersion: "0.1.0",
                    vscode: CompanionVSCodeIdentity(
                        edition: "vscode", version: "1.94.0",
                        profileName: "Default", profileId: "p", machineId: "m",
                        sessionId: "s", processId: 1, windowId: "w"
                    ),
                    capabilities: ["colorTheme"],
                    currentSettings: [:]
                )
            )
        )

        guard case .registerRejected(let rejection) = try client.receive() else {
            Issue.record("expected register_rejected")
            return
        }
        #expect(rejection.reason == .invalidNonce)
        // The server should close the connection after rejecting; the
        // next receive returns nil.
        #expect(try client.receive() == nil)
    }

    @Test("A malformed frame produces a protocol_error and closes the connection")
    func malformedFrameClosesConnection() throws {
        let fixture = try Fixture()
        try fixture.server.start()
        defer { fixture.server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        let client = try TestClient(socketPath: fixture.paths.socketFile.path)
        try client.sendRaw(Data("not json".utf8))

        guard case .protocolError(let error) = try client.receive(timeout: 1) else {
            Issue.record("expected protocol_error")
            return
        }
        #expect(error.code == .malformedFrame)
        #expect(try client.receive(timeout: 1) == nil)
    }

    @Test("The server tolerates a leftover socket file from a prior launch")
    func rebindClearsStaleSocket() throws {
        let fixture = try Fixture()

        // Pre-create the socket file to simulate a crashed prior launch.
        try FileManager.default.createDirectory(
            at: fixture.paths.launchDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data("stale".utf8).write(to: fixture.paths.socketFile)

        try fixture.server.start()
        defer { fixture.server.stop() }

        Thread.sleep(forTimeInterval: 0.05)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.socketFile.path))
    }

    // MARK: - Reconnects

    @Test("Requests route to the exact registered server session")
    func requestsRouteToExactSession() async throws {
        let fixture = try Fixture(launchNonce: "route-nonce")
        try fixture.server.start()
        defer { fixture.server.stop() }

        let first = try TestClient(socketPath: fixture.paths.socketFile.path)
        let firstAck = try register(
            first,
            nonce: "route-nonce",
            profileID: "profile-1",
            windowID: "window-1"
        )
        let second = try TestClient(socketPath: fixture.paths.socketFile.path)
        let secondAck = try register(
            second,
            nonce: "route-nonce",
            profileID: "profile-2",
            windowID: "window-2"
        )

        let server = fixture.server
        let selectedSessionID = secondAck.sessionId
        let task = Task {
            try await server.inspectTheme(serverSessionID: selectedSessionID)
        }
        guard case .inspectTheme(let request) = try second.receive() else {
            Issue.record("expected inspect_theme on the selected session")
            return
        }
        #expect(try first.receive(timeout: 0.1) == nil)
        #expect(firstAck.sessionId != secondAck.sessionId)

        try second.send(
            .inspectThemeAck(
                .init(
                    protocolVersion: 1,
                    id: request.id,
                    configuredSetting: "Mocha",
                    effectiveSetting: "Solarized Dark",
                    overrides: [.init(scope: .workspace, folder: nil, value: "Solarized Dark")]
                )
            )
        )
        let inspection = try await task.value
        #expect(inspection.configuredSetting == "Mocha")
        #expect(inspection.effectiveSetting == "Solarized Dark")
    }

    @Test("An unanswered request fails at the configured timeout")
    func requestTimesOut() async throws {
        let fixture = try Fixture(launchNonce: "timeout-nonce", requestTimeout: 0.05)
        try fixture.server.start()
        defer { fixture.server.stop() }
        let client = try TestClient(socketPath: fixture.paths.socketFile.path)
        let ack = try register(client, nonce: "timeout-nonce")
        let server = fixture.server
        let sessionID = ack.sessionId

        let task = Task {
            try await server.inspectTheme(serverSessionID: sessionID)
        }
        guard case .inspectTheme(let request) = try client.receive() else {
            Issue.record("expected inspect_theme")
            return
        }

        do {
            _ = try await task.value
            Issue.record("expected timeout")
        } catch let error as VSCodeCompanionRequestError {
            #expect(error == .timeout)
        }

        try client.send(
            .inspectThemeAck(
                .init(
                    protocolVersion: 1,
                    id: request.id,
                    configuredSetting: "late",
                    effectiveSetting: "late",
                    overrides: []
                )
            )
        )
        guard case .protocolError(let error) = try client.receive() else {
            Issue.record("expected stale acknowledgement protocol error")
            return
        }
        #expect(error.code == .unexpectedMessage)
    }

    @Test("Closing a target connection fails its pending request as disconnected")
    func connectionCloseFailsPendingRequest() async throws {
        let fixture = try Fixture(launchNonce: "disconnect-nonce")
        try fixture.server.start()
        defer { fixture.server.stop() }
        let client = try TestClient(socketPath: fixture.paths.socketFile.path)
        let ack = try register(client, nonce: "disconnect-nonce")
        let server = fixture.server
        let sessionID = ack.sessionId

        let task = Task {
            try await server.inspectTheme(serverSessionID: sessionID)
        }
        guard case .inspectTheme = try client.receive() else {
            Issue.record("expected inspect_theme")
            return
        }
        client.close()

        do {
            _ = try await task.value
            Issue.record("expected disconnect")
        } catch let error as VSCodeCompanionRequestError {
            #expect(error == .disconnected)
        }
    }

    @Test("A correlated peer protocol error reaches the apply caller")
    func correlatedProtocolErrorFailsApply() async throws {
        let fixture = try Fixture(launchNonce: "error-nonce")
        try fixture.server.start()
        defer { fixture.server.stop() }
        let client = try TestClient(socketPath: fixture.paths.socketFile.path)
        let ack = try register(client, nonce: "error-nonce")
        let request = VSCodeCompanionThemeRequest(
            protocolVersion: 1,
            themeName: "Mocha",
            expectedSetting: "Default Dark+",
            target: .global
        )
        let server = fixture.server
        let sessionID = ack.sessionId

        let task = Task {
            try await server.applyTheme(request, serverSessionID: sessionID)
        }
        guard case .applyTheme(let wireRequest) = try client.receive() else {
            Issue.record("expected apply_theme")
            return
        }
        try client.send(
            .protocolError(
                .init(
                    protocolVersion: 1,
                    id: UUID(),
                    requestId: wireRequest.id,
                    code: .duplicateRequestID,
                    message: "duplicate"
                )
            )
        )

        do {
            _ = try await task.value
            Issue.record("expected duplicate request failure")
        } catch let error as VSCodeCompanionRequestError {
            #expect(error == .duplicateRequest)
        }
    }

    @Test("A semantically mismatched apply acknowledgement is malformed")
    func mismatchedApplyAcknowledgementIsMalformed() async throws {
        let fixture = try Fixture(launchNonce: "mismatch-nonce")
        try fixture.server.start()
        defer { fixture.server.stop() }
        let client = try TestClient(socketPath: fixture.paths.socketFile.path)
        let ack = try register(client, nonce: "mismatch-nonce")
        let request = VSCodeCompanionThemeRequest(
            protocolVersion: 1,
            themeName: "Mocha",
            expectedSetting: "Default Dark+",
            target: .global
        )
        let server = fixture.server
        let sessionID = ack.sessionId

        let task = Task {
            try await server.applyTheme(request, serverSessionID: sessionID)
        }
        guard case .applyTheme(let wireRequest) = try client.receive() else {
            Issue.record("expected apply_theme")
            return
        }
        try client.send(
            .applyThemeAck(
                .init(
                    protocolVersion: 1,
                    id: wireRequest.id,
                    status: .applied,
                    effectiveSetting: "Other",
                    requestedSetting: "Other",
                    configuredSetting: "Other",
                    overrides: [],
                    failure: nil
                )
            )
        )

        do {
            _ = try await task.value
            Issue.record("expected malformed acknowledgement")
        } catch let error as VSCodeCompanionRequestError {
            #expect(error == .malformedAcknowledgement)
        }
    }

    @Test("A client can disconnect and reconnect within one launch")
    func reconnectWithinLaunch() throws {
        let fixture = try Fixture(launchNonce: "n-1")
        try fixture.server.start()
        defer { fixture.server.stop() }
        Thread.sleep(forTimeInterval: 0.05)

        for _ in 0..<3 {
            let client = try TestClient(socketPath: fixture.paths.socketFile.path)
            try client.send(
                .register(
                    CompanionRegisterMessage(
                        protocolVersion: 1,
                        id: UUID(),
                        launchNonce: "n-1",
                        extensionVersion: "0.1.0",
                        vscode: CompanionVSCodeIdentity(
                            edition: "vscode", version: "1.94.0",
                            profileName: "Default", profileId: "p", machineId: "m",
                            sessionId: "s", processId: 1, windowId: "w"
                        ),
                        capabilities: ["colorTheme"],
                        currentSettings: [:]
                    )
                )
            )
            guard case .registerAck = try client.receive() else {
                Issue.record("expected register_ack")
                return
            }
        }
    }

    private func register(
        _ client: TestClient,
        nonce: String,
        profileID: String = "profile",
        windowID: String = "window"
    ) throws -> CompanionRegisterAckMessage {
        try client.send(
            .register(
                CompanionRegisterMessage(
                    protocolVersion: 1,
                    id: UUID(),
                    launchNonce: nonce,
                    extensionVersion: "0.1.0",
                    vscode: CompanionVSCodeIdentity(
                        edition: "vscode",
                        version: "1.95.2",
                        profileName: "Default",
                        profileId: profileID,
                        machineId: "machine",
                        sessionId: windowID,
                        processId: 42,
                        windowId: windowID
                    ),
                    capabilities: ["colorTheme"],
                    currentSettings: ["workbench.colorTheme": "Default Dark+"]
                )
            )
        )
        guard case .registerAck(let acknowledgement) = try client.receive() else {
            throw TestClientError.missingRegisterAcknowledgement
        }
        return acknowledgement
    }

    private enum TestClientError: Error {
        case missingRegisterAcknowledgement
    }
}
