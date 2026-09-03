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
    /// Maximum time to await an inspect or apply acknowledgement.
    public let requestTimeout: TimeInterval
    /// Peer euid the server expects. Defaults to the app's own euid.
    public let expectedPeerEUID: uid_t

    public init(
        paths: CompanionSocketPaths,
        launchID: String,
        launchNonce: String,
        sessionIDProvider: @escaping @Sendable () -> String = { UUID().uuidString },
        registerTimeout: TimeInterval = 5,
        requestTimeout: TimeInterval = 5,
        expectedPeerEUID: uid_t = geteuid()
    ) {
        self.paths = paths
        self.launchID = launchID
        self.launchNonce = launchNonce
        self.sessionIDProvider = sessionIDProvider
        self.registerTimeout = registerTimeout
        self.requestTimeout = requestTimeout
        self.expectedPeerEUID = expectedPeerEUID
    }
}

// MARK: - Ack callback

/// Result of an `applyTheme` round-trip against a connected extension.
public struct CompanionApplyOutcome: Equatable, Sendable {
    public let sessionID: String
    public let acknowledgement: CompanionApplyThemeAckMessage

    public init(sessionID: String, acknowledgement: CompanionApplyThemeAckMessage) {
        self.sessionID = sessionID
        self.acknowledgement = acknowledgement
    }
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

    private struct PendingInspection {
        let connectionID: UUID
        let timer: DispatchSourceTimer
        let continuation: CheckedContinuation<CompanionThemeInspection, Error>
    }

    private struct PendingApply {
        let connectionID: UUID
        let timer: DispatchSourceTimer
        let continuation: CheckedContinuation<CompanionApplyOutcome, Error>
    }

    private var pendingInspections: [UUID: PendingInspection] = [:]
    private var pendingApplies: [UUID: PendingApply] = [:]

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

    /// Returns the currently authenticated companion registrations. Closed
    /// connections disappear from this snapshot.
    public func registrations() -> [CompanionRegistration] {
        queue.sync {
            connections.values.compactMap(\.registration).sorted {
                $0.serverSessionID < $1.serverSessionID
            }
        }
    }

    /// Inspect the theme state of one exact registered server session.
    public func inspectTheme(
        serverSessionID: String
    ) async throws -> CompanionThemeInspection {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<CompanionThemeInspection, Error>) in
            queue.async {
                guard self.isRunning else {
                    continuation.resume(throwing: VSCodeCompanionRequestError.notRunning)
                    return
                }
                guard let connection = self.connection(serverSessionID: serverSessionID) else {
                    continuation.resume(throwing: VSCodeCompanionRequestError.targetUnavailable)
                    return
                }
                let effects = connection.sendInspectTheme()
                guard case .send(.inspectTheme(let request))? = effects.first else {
                    continuation.resume(throwing: VSCodeCompanionRequestError.disconnected)
                    return
                }
                let timer = self.makeRequestTimer(requestID: request.id)
                self.pendingInspections[request.id] = PendingInspection(
                    connectionID: connection.identifier,
                    timer: timer,
                    continuation: continuation
                )
                timer.resume()
                self.handle(effects: effects, from: connection)
            }
        }
    }

    /// Apply a versioned, guarded theme request to one exact registered server session.
    public func applyTheme(
        _ request: VSCodeCompanionThemeRequest,
        serverSessionID: String
    ) async throws -> CompanionApplyOutcome {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<CompanionApplyOutcome, Error>) in
            queue.async {
                guard self.isRunning else {
                    continuation.resume(throwing: VSCodeCompanionRequestError.notRunning)
                    return
                }
                guard let connection = self.connection(serverSessionID: serverSessionID) else {
                    continuation.resume(throwing: VSCodeCompanionRequestError.targetUnavailable)
                    return
                }
                let effects: [CompanionServerEffect]
                do {
                    effects = try connection.sendApplyTheme(request)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                guard case .send(.applyTheme(let message))? = effects.first else {
                    continuation.resume(throwing: VSCodeCompanionRequestError.disconnected)
                    return
                }
                let timer = self.makeRequestTimer(requestID: message.id)
                self.pendingApplies[message.id] = PendingApply(
                    connectionID: connection.identifier,
                    timer: timer,
                    continuation: continuation
                )
                timer.resume()
                self.handle(effects: effects, from: connection)
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

        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
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
        failPendingRequests(
            forConnectionID: connection.identifier,
            error: .disconnected
        )
    }

    private func connection(serverSessionID: String) -> CompanionConnection? {
        connections.values.first {
            $0.registration?.serverSessionID == serverSessionID
        }
    }

    private func makeRequestTimer(requestID: UUID) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + max(0, configuration.requestTimeout),
            leeway: .milliseconds(10)
        )
        timer.setEventHandler { [weak self] in
            self?.requestTimedOut(requestID: requestID)
        }
        return timer
    }

    private func requestTimedOut(requestID: UUID) {
        if let pending = pendingInspections.removeValue(forKey: requestID) {
            pending.timer.cancel()
            connections[pending.connectionID]?.cancelRequest(id: requestID)
            pending.continuation.resume(throwing: VSCodeCompanionRequestError.timeout)
            return
        }
        if let pending = pendingApplies.removeValue(forKey: requestID) {
            pending.timer.cancel()
            connections[pending.connectionID]?.cancelRequest(id: requestID)
            pending.continuation.resume(throwing: VSCodeCompanionRequestError.timeout)
        }
    }

    private func failPendingRequests(
        forConnectionID connectionID: UUID,
        error: VSCodeCompanionRequestError
    ) {
        let inspectionIDs = pendingInspections.compactMap { requestID, pending in
            pending.connectionID == connectionID ? requestID : nil
        }
        for requestID in inspectionIDs {
            guard let pending = pendingInspections.removeValue(forKey: requestID) else { continue }
            pending.timer.cancel()
            pending.continuation.resume(throwing: error)
        }

        let applyIDs = pendingApplies.compactMap { requestID, pending in
            pending.connectionID == connectionID ? requestID : nil
        }
        for requestID in applyIDs {
            guard let pending = pendingApplies.removeValue(forKey: requestID) else { continue }
            pending.timer.cancel()
            pending.continuation.resume(throwing: error)
        }
    }

    private func failRequest(id: UUID, error: VSCodeCompanionRequestError) {
        if let pending = pendingInspections.removeValue(forKey: id) {
            pending.timer.cancel()
            pending.continuation.resume(throwing: error)
            return
        }
        if let pending = pendingApplies.removeValue(forKey: id) {
            pending.timer.cancel()
            pending.continuation.resume(throwing: error)
        }
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
            case .deliverInspectionAcknowledgement(let acknowledgement):
                if let pending = pendingInspections.removeValue(forKey: acknowledgement.id) {
                    pending.timer.cancel()
                    pending.continuation.resume(
                        returning: CompanionThemeInspection(
                            configuredSetting: acknowledgement.configuredSetting,
                            effectiveSetting: acknowledgement.effectiveSetting,
                            overrides: acknowledgement.overrides
                        )
                    )
                }
            case .deliverAcknowledgement(let acknowledgement):
                if let pending = pendingApplies.removeValue(forKey: acknowledgement.id) {
                    pending.timer.cancel()
                    pending.continuation.resume(
                        returning: CompanionApplyOutcome(
                            sessionID: connection.sessionID ?? "",
                            acknowledgement: acknowledgement
                        )
                    )
                }
            case .failRequest(let id, let error):
                failRequest(id: id, error: error)
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

        for connection in Array(connections.values) {
            connection.close()
        }
        connections.removeAll()

        for pending in pendingInspections.values {
            pending.timer.cancel()
            pending.continuation.resume(throwing: VSCodeCompanionRequestError.notRunning)
        }
        pendingInspections.removeAll()
        for pending in pendingApplies.values {
            pending.timer.cancel()
            pending.continuation.resume(throwing: VSCodeCompanionRequestError.notRunning)
        }
        pendingApplies.removeAll()

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
    var registration: CompanionRegistration? { session.registration }

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

    func sendInspectTheme() -> [CompanionServerEffect] {
        session.sendInspectTheme()
    }

    func sendApplyTheme(
        _ request: VSCodeCompanionThemeRequest
    ) throws -> [CompanionServerEffect] {
        try session.sendApplyTheme(request)
    }

    func cancelRequest(id: UUID) {
        session.cancelRequest(id: id)
    }
}
