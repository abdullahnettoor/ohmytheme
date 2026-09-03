import Darwin
import Dispatch
import Foundation

// macOS defines these in <sys/un.h> but Swift doesn't always import
// them as constants. See <sys/un.h> for the canonical values.
private let solLocal: Int32 = 0
private let localPeerEUID: Int32 = 0x006
private let maxSunPath: Int = 104

// MARK: - Errors

/// Failures reported by the companion socket server. They surface
/// configuration mistakes and OS-level socket errors; wire-protocol
/// violations are reported inside the connection as `protocol_error`
/// messages rather than thrown here.
public enum CompanionSocketServerError: Error, Equatable {
    case socketPathTooLong(Int, max: Int)
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case writeFailed(Int32)
    case alreadyRunning
    case notRunning
}

// MARK: - Configuration

/// Static configuration for a companion socket server instance.
///
/// Callers construct one per app launch. The launch identifier and
/// nonce are generated once at launch; they never rotate while the
/// server is running.
public struct CompanionSocketServerConfiguration: Sendable {
    /// Paths used for the socket, rendezvous file, and per-launch
    /// directory.
    public let paths: CompanionSocketPaths
    /// Unique identifier for this launch, embedded in the launch
    /// directory path and rendezvous file.
    public let launchID: String
    /// Nonce the extension must present in `register.launchNonce`.
    public let launchNonce: String
    /// Session-id provider handed to each `CompanionServerSession`.
    /// Defaults to a random UUID string.
    public let sessionIDProvider: @Sendable () -> String
    /// Register timeout applied to each new connection. A connection
    /// that has not sent `register` within this window is closed.
    public let registerTimeout: TimeInterval
    /// Peer euid the server expects. Defaults to the app's own euid.
    public let expectedPeerEUID: uid_t

    public init(
        paths: CompanionSocketPaths,
        launchID: String,
        launchNonce: String,
        sessionIDProvider: @escaping @Sendable () -> String = { UUID().uuidString },
        registerTimeout: TimeInterval = 5,
        expectedPeerEUID: uid_t = geteuid()
    ) {
        self.paths = paths
        self.launchID = launchID
        self.launchNonce = launchNonce
        self.sessionIDProvider = sessionIDProvider
        self.registerTimeout = registerTimeout
        self.expectedPeerEUID = expectedPeerEUID
    }
}

// MARK: - Ack callback

/// Result of an `applyTheme` round-trip against a connected extension.
public struct CompanionApplyOutcome: Sendable {
    public let sessionID: String
    public let acknowledgement: CompanionApplyThemeAckMessage
}

// MARK: - Server

/// Unix-domain socket server that hosts one or more companion
/// extensions per launch.
///
/// The server binds a per-launch socket, publishes a rendezvous file
/// the extension reads to discover it, verifies each accepting peer's
/// effective user id, and drives one `CompanionServerSession` per
/// connection. It converts session effects into framed socket writes
/// and delivers acknowledgements back to `applyTheme` callers.
public final class CompanionSocketServer: @unchecked Sendable {

    private let configuration: CompanionSocketServerConfiguration
    private let queue = DispatchQueue(label: "ohmytheme.companion.socket")
    private let acceptQueue = DispatchQueue(label: "ohmytheme.companion.accept")

    // All state below is accessed only on `queue`.
    private var listenerFD: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var connections: [UUID: CompanionConnection] = [:]
    private var isRunning = false

    /// Continuations awaiting an ack for a given request id.
    private var pendingAcks: [UUID: CheckedContinuation<CompanionApplyOutcome, Error>] = [:]

    public init(configuration: CompanionSocketServerConfiguration) {
        self.configuration = configuration
    }

    deinit {
        stopSynchronously()
    }

    // MARK: - Public API

    /// Bind the socket, write the rendezvous file, and start
    /// accepting connections. The server tolerates a leftover socket
    /// from a crashed launch by unlinking it before binding.
    public func start() throws {
        try queue.sync {
            guard !isRunning else { throw CompanionSocketServerError.alreadyRunning }
            try bindAndListen()
            try publishRendezvous()
            installAcceptSource()
            isRunning = true
        }
    }

    /// Close every connection, stop accepting, remove the rendezvous
    /// file, and delete the launch directory.
    public func stop() {
        queue.sync { stopSynchronously() }
    }

    /// Send an `apply_theme` request to the first registered
    /// connection and await its acknowledgement, or fail if none is
    /// registered.
    public func applyTheme(
        themeName: String
    ) async throws -> CompanionApplyOutcome {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<CompanionApplyOutcome, Error>) in
            queue.async {
                guard
                    let connection = self.connections.values.first(where: {
                        $0.isRegistered
                    })
                else {
                    continuation.resume(
                        throwing: CompanionSocketServerError.notRunning)
                    return
                }
                let effects = connection.sendApplyTheme(themeName: themeName)
                var requestID: UUID? = nil
                for effect in effects {
                    if case .send(.applyTheme(let request)) = effect {
                        requestID = request.id
                    }
                }
                guard let id = requestID else {
                    continuation.resume(throwing: CompanionSocketServerError.notRunning)
                    return
                }
                self.pendingAcks[id] = continuation
            }
        }
    }

    // MARK: - Bind / listen / accept

    private func bindAndListen() throws {
        try CompanionFilesystem.ensurePrivateDirectory(at: configuration.paths.root)
        try CompanionFilesystem.ensurePrivateDirectory(at: configuration.paths.launchDirectory)

        // Remove any leftover socket file before binding.
        CompanionFilesystem.removeItemIfPresent(at: configuration.paths.socketFile)

        let path = configuration.paths.socketFile.path
        guard path.utf8.count < maxSunPath else {
            throw CompanionSocketServerError.socketPathTooLong(
                path.utf8.count, max: maxSunPath - 1)
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CompanionSocketServerError.socketCreationFailed(errno)
        }
        var nosigpipe: Int32 = 1
        _ = setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE,
            &nosigpipe, socklen_t(MemoryLayout<Int32>.size)
        )

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Copy path into sun_path (fixed-size C array).
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { rawPtr in
            rawPtr.withMemoryRebound(to: CChar.self, capacity: maxSunPath) { chars in
                path.withCString { source in
                    strncpy(chars, source, maxSunPath - 1)
                }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, addrLen)
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            throw CompanionSocketServerError.bindFailed(err)
        }
        // Restrict the socket file to owner read/write.
        chmod(path, 0o600)

        guard Darwin.listen(fd, 4) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw CompanionSocketServerError.listenFailed(err)
        }

        listenerFD = fd
    }

    private func publishRendezvous() throws {
        let rendezvous = CompanionRendezvous(
            socketPath: configuration.paths.socketFile.path,
            launchId: configuration.launchID,
            launchNonce: configuration.launchNonce,
            protocolVersion: CompanionProtocol.currentVersion,
            supportedProtocolVersions: Array(CompanionProtocol.supportedVersions)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rendezvous)
        try CompanionFilesystem.writePrivateFile(data, to: configuration.paths.rendezvousFile)
    }

    private func installAcceptSource() {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: listenerFD, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections()
        }
        source.resume()
        listenerSource = source
    }

    private func acceptPendingConnections() {
        while true {
            var addr = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &addr) { pointer -> Int32 in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rawAddr in
                    Darwin.accept(listenerFD, rawAddr, &length)
                }
            }
            if clientFD < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                return
            }
            queue.async {
                self.attachConnection(fd: clientFD)
            }
        }
    }

    /// Set SO_NOSIGPIPE on an accepted client fd so a broken pipe on
    /// write produces `EPIPE` instead of terminating the process.
    private static func suppressSIGPIPE(fd: Int32) {
        var value: Int32 = 1
        _ = setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE,
            &value, socklen_t(MemoryLayout<Int32>.size)
        )
    }

    // MARK: - Connection lifecycle

    private func attachConnection(fd: Int32) {
        Self.suppressSIGPIPE(fd: fd)
        guard verifyPeerEUID(fd: fd) else {
            Darwin.close(fd)
            return
        }
        let connection = CompanionConnection(
            fd: fd,
            queue: queue,
            configuration: configuration,
            onEffects: { [weak self] connection, effects in
                self?.handle(effects: effects, from: connection)
            },
            onClose: { [weak self] connection in
                self?.removeConnection(connection)
            }
        )
        connections[connection.identifier] = connection
        connection.start()
    }

    private func verifyPeerEUID(fd: Int32) -> Bool {
        var euid: uid_t = 0
        var len = socklen_t(MemoryLayout<uid_t>.size)
        let result = getsockopt(fd, solLocal, localPeerEUID, &euid, &len)
        guard result == 0 else { return false }
        return euid == configuration.expectedPeerEUID
    }

    private func removeConnection(_ connection: CompanionConnection) {
        connections.removeValue(forKey: connection.identifier)
    }

    private func handle(
        effects: [CompanionServerEffect], from connection: CompanionConnection
    ) {
        for effect in effects {
            switch effect {
            case .send(let message):
                connection.write(message: message)
            case .close:
                connection.close()
            case .deliverAcknowledgement(let ack):
                if let waiter = pendingAcks.removeValue(forKey: ack.id) {
                    waiter.resume(
                        returning: CompanionApplyOutcome(
                            sessionID: connection.sessionID ?? "",
                            acknowledgement: ack
                        )
                    )
                }
            }
        }
    }

    // MARK: - Shutdown

    private func stopSynchronously() {
        guard isRunning else { return }
        isRunning = false

        listenerSource?.cancel()
        listenerSource = nil

        if listenerFD >= 0 {
            Darwin.close(listenerFD)
            listenerFD = -1
        }

        for connection in connections.values {
            connection.close()
        }
        connections.removeAll()

        for continuation in pendingAcks.values {
            continuation.resume(throwing: CompanionSocketServerError.notRunning)
        }
        pendingAcks.removeAll()

        CompanionFilesystem.removeItemIfPresent(at: configuration.paths.rendezvousFile)
        CompanionFilesystem.removeItemIfPresent(at: configuration.paths.socketFile)
        CompanionFilesystem.removeItemIfPresent(at: configuration.paths.launchDirectory)
    }
}

// MARK: - Connection

/// One accepted socket. Owns its file descriptor, reads frames from it,
/// pushes decoded bodies into a `CompanionServerSession`, and turns
/// session effects into framed writes and connection closures.
final class CompanionConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private let configuration: CompanionSocketServerConfiguration
    private var readSource: DispatchSourceRead?
    private var session: CompanionServerSession
    private var decoder = CompanionFrameDecoder()
    private var closed = false
    private var registerTimer: DispatchSourceTimer?

    private let onEffects: (CompanionConnection, [CompanionServerEffect]) -> Void
    private let onClose: (CompanionConnection) -> Void

    /// Stable identity used to look up connections in the server. We
    /// need something the server can key its dictionary on before
    /// the session assigns an id.
    let identifier: UUID = UUID()
    private(set) var sessionID: String?

    var isRegistered: Bool { session.isRegistered }

    init(
        fd: Int32,
        queue: DispatchQueue,
        configuration: CompanionSocketServerConfiguration,
        onEffects: @escaping (CompanionConnection, [CompanionServerEffect]) -> Void,
        onClose: @escaping (CompanionConnection) -> Void
    ) {
        self.fd = fd
        self.queue = queue
        self.configuration = configuration
        self.onEffects = onEffects
        self.onClose = onClose
        self.session = CompanionServerSession(
            launchNonce: configuration.launchNonce,
            supportedProtocolVersions: CompanionProtocol.supportedVersions,
            sessionIdProvider: configuration.sessionIDProvider
        )
    }

    func start() {
        // Non-blocking so we can drain the socket in the read handler.
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        readSource = source

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + configuration.registerTimeout,
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let effects = self.session.onRegisterTimeout()
            self.onEffects(self, effects)
        }
        timer.resume()
        registerTimer = timer
    }

    /// Send a wire message. Encodes and writes synchronously on the
    /// server queue. Failures close the connection.
    func write(message: CompanionMessage) {
        do {
            let body = try CompanionMessageCodec.encodeBody(message)
            let framed = CompanionFrame.encode(body: body)
            try framed.withUnsafeBytes { raw in
                var written = 0
                while written < raw.count {
                    let base = raw.baseAddress!.advanced(by: written)
                    let result = Darwin.write(fd, base, raw.count - written)
                    if result < 0 {
                        if errno == EINTR { continue }
                        if errno == EAGAIN || errno == EWOULDBLOCK {
                            // The buffer is full; wait briefly. For this
                            // proof the buffer is not expected to fill.
                            usleep(1_000)
                            continue
                        }
                        throw CompanionSocketServerError.writeFailed(errno)
                    }
                    written += result
                }
            }
        } catch {
            close()
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        registerTimer?.cancel()
        registerTimer = nil
        readSource?.cancel()
        readSource = nil
        // Half-close write first so the peer sees EOF immediately,
        // then release the descriptor.
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        onClose(self)
    }

    private func readAvailable() {
        guard !closed else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = buffer.withUnsafeMutableBufferPointer {
                Darwin.read(fd, $0.baseAddress, $0.count)
            }
            if bytesRead > 0 {
                decoder.append(Data(bytes: buffer, count: bytesRead))
                drainFrames()
                continue
            }
            if bytesRead == 0 {
                // Peer closed cleanly.
                close()
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            if errno == EINTR { continue }
            // Unrecoverable read error.
            close()
            return
        }
    }

    private func drainFrames() {
        while true {
            let body: Data?
            do {
                body = try decoder.nextFrame()
            } catch let error as CompanionProtocolError {
                let message = CompanionMessage.protocolError(
                    CompanionProtocolErrorMessage(
                        protocolVersion: CompanionProtocol.currentVersion,
                        id: UUID(),
                        requestId: nil,
                        code: error.wireCode,
                        message: error.wireMessage
                    )
                )
                onEffects(self, [.send(message), .close])
                return
            } catch {
                onEffects(self, [.close])
                return
            }
            guard let bodyData = body else { return }
            let effects = session.receive(body: bodyData)
            if session.isRegistered { sessionID = session.negotiatedSessionID }
            onEffects(self, effects)
            if closed { return }
        }
    }

    func sendApplyTheme(themeName: String) -> [CompanionServerEffect] {
        let effects = session.sendApplyTheme(themeName: themeName)
        onEffects(self, effects)
        return effects
    }
}
