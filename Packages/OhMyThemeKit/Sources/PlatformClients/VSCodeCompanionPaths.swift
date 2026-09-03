import Darwin
import Foundation

// MARK: - Paths

/// Filesystem layout for one launch of the companion server.
///
/// The application-support root and its rendezvous file are shared
/// across launches (only one is ever present at a time). The socket
/// uses a short private root because macOS limits Unix-domain paths to
/// 103 bytes. Its launch directory is unique so a stale socket cannot
/// be reused by a later process.
public struct CompanionSocketPaths: Equatable, Sendable {
    /// Application Support directory that contains the rendezvous
    /// file. Created with mode 0700.
    public let root: URL

    /// Short private directory that contains per-launch socket
    /// directories. Created with mode 0700.
    public let socketRoot: URL

    /// Path to the rendezvous JSON file, atomically replaced each
    /// launch and chmoded to 0600.
    public let rendezvousFile: URL

    /// Unique per-launch directory that holds the Unix-domain socket.
    /// Created with mode 0700 and removed on shutdown.
    public let launchDirectory: URL

    /// Unix-domain socket path. `sun_path` has a strict length limit
    /// on macOS (104 bytes), so callers should keep the root short.
    public let socketFile: URL

    public init(root: URL, socketRoot: URL? = nil, launchID: String) {
        self.root = root
        self.socketRoot = socketRoot ?? root
        self.rendezvousFile = root.appendingPathComponent("rendezvous.json")
        self.launchDirectory = self.socketRoot.appendingPathComponent(launchID, isDirectory: true)
        self.socketFile = self.launchDirectory.appendingPathComponent("companion.sock")
    }

    /// The canonical location the app uses in production, under
    /// Application Support. Callers pass in a temporary root for
    /// tests.
    public static func productionRoot(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return
            base
            .appendingPathComponent("OhMyTheme", isDirectory: true)
            .appendingPathComponent("companion", isDirectory: true)
    }

    public static func production(
        launchID: String,
        fileManager: FileManager = .default,
        effectiveUserID: uid_t = geteuid()
    ) throws -> CompanionSocketPaths {
        CompanionSocketPaths(
            root: try productionRoot(fileManager: fileManager),
            socketRoot: URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("omt-\(effectiveUserID)", isDirectory: true),
            launchID: launchID
        )
    }
}

// MARK: - Rendezvous

/// The JSON structure the server writes to `rendezvous.json` and the
/// extension reads to discover the current socket.
public struct CompanionRendezvous: Codable, Equatable, Sendable {
    public let socketPath: String
    public let launchId: String
    public let launchNonce: String
    public let protocolVersion: Int
    public let supportedProtocolVersions: [Int]

    public init(
        socketPath: String,
        launchId: String,
        launchNonce: String,
        protocolVersion: Int,
        supportedProtocolVersions: [Int]
    ) {
        self.socketPath = socketPath
        self.launchId = launchId
        self.launchNonce = launchNonce
        self.protocolVersion = protocolVersion
        self.supportedProtocolVersions = supportedProtocolVersions
    }
}

// MARK: - File utilities

enum CompanionFilesystemError: Error {
    case unsafePrivateDirectory(String)
    case privateDirectoryOwnerMismatch(path: String, expected: uid_t, actual: uid_t)
    case chmodFailed(path: String, code: Int32)
}

enum CompanionFilesystem {
    /// Create the directory tree at `url` if needed and force its mode
    /// to `0700`. `chmod` runs even when the directory already exists
    /// so a permissive leftover cannot persist across launches.
    static func ensurePrivateDirectory(at url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        var status = stat()
        guard lstat(url.path, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR
        else {
            throw CompanionFilesystemError.unsafePrivateDirectory(url.path)
        }
        let expectedOwner = geteuid()
        guard status.st_uid == expectedOwner else {
            throw CompanionFilesystemError.privateDirectoryOwnerMismatch(
                path: url.path,
                expected: expectedOwner,
                actual: status.st_uid
            )
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw CompanionFilesystemError.chmodFailed(path: url.path, code: errno)
        }
    }

    /// Atomically write `data` to `url` and chmod the result to 0600.
    static func writePrivateFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Remove an item at `url` and swallow "no such file" errors.
    static func removeItemIfPresent(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError
        {
            return
        } catch {
            // Best-effort cleanup: nothing we can do here.
            return
        }
    }
}
