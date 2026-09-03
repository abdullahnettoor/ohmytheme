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
        let root: URL
        let server: CompanionSocketServer
        let paths: CompanionSocketPaths
        let launchID: String
        let launchNonce: String

        init(
            launchID: String = UUID().uuidString,
            launchNonce: String = UUID().uuidString,
            expectedPeerEUID: uid_t = geteuid(),
            registerTimeout: TimeInterval = 5
        ) throws {
            // Keep the root path short: `sun_path` is capped at 104 bytes.
            let short = "omt-\(UUID().uuidString.prefix(8))"
            self.root = URL(fileURLWithPath: "/tmp/\(short)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            self.launchID = launchID
            self.launchNonce = launchNonce
            self.paths = CompanionSocketPaths(root: root, launchID: launchID)
            self.server = CompanionSocketServer(
                configuration: CompanionSocketServerConfiguration(
                    paths: paths,
                    launchID: launchID,
                    launchNonce: launchNonce,
                    registerTimeout: registerTimeout,
                    expectedPeerEUID: expectedPeerEUID
                )
            )
        }

        deinit {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Simple synchronous test client: opens the Unix-domain socket,
    /// speaks the framed protocol, and closes.
    final class TestClient {
        let fd: Int32
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

        deinit { Darwin.close(fd) }

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

        let dirMode =
            try fm.attributesOfItem(atPath: fixture.paths.root.path)[
                .posixPermissions] as? NSNumber
        #expect(dirMode?.uint16Value == 0o700)
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
}
