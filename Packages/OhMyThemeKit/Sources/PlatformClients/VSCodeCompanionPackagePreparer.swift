import CryptoKit
import Foundation

public struct PreparedVSCodeCompanionPackage: Equatable, Sendable {
    public let vsixURL: URL
    public let workingDirectory: URL

    public init(vsixURL: URL, workingDirectory: URL) {
        self.vsixURL = vsixURL
        self.workingDirectory = workingDirectory
    }
}

public protocol VSCodeCompanionPackagePreparing: Sendable {
    func prepare(
        _ artifact: VSCodeCompanionArtifact,
        ownershipToken: String
    ) async throws -> PreparedVSCodeCompanionPackage

    func remove(_ package: PreparedVSCodeCompanionPackage)
}

public enum VSCodeCompanionPackageError: Error, Equatable, Sendable {
    case invalidArchive
    case archiveCommandFailed(status: Int32, detail: String)
}

/// Adds a per-connection ownership record to a temporary copy of the pinned
/// VSIX before VS Code installs it. The record and extension files therefore
/// arrive in one CLI installation rather than in two externally visible steps.
public final class VSCodeCompanionPackagePreparer: VSCodeCompanionPackagePreparing,
    @unchecked Sendable
{
    private let processRunner: any ProcessRunning
    private let fileManager: FileManager

    public init(
        processRunner: any ProcessRunning = ProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    public func prepare(
        _ artifact: VSCodeCompanionArtifact,
        ownershipToken: String
    ) async throws -> PreparedVSCodeCompanionPackage {
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("oh-my-theme-vsix-\(UUID().uuidString)", isDirectory: true)
        let expanded = workingDirectory.appendingPathComponent("expanded", isDirectory: true)
        let output = workingDirectory.appendingPathComponent("owned.vsix")
        try fileManager.createDirectory(at: expanded, withIntermediateDirectories: true)
        do {
            try await runDitto(arguments: ["-x", "-k", artifact.vsixURL.path, expanded.path])
            let extensionDirectory = expanded.appendingPathComponent("extension", isDirectory: true)
            guard fileManager.fileExists(atPath: extensionDirectory.path) else {
                throw VSCodeCompanionPackageError.invalidArchive
            }
            try VSCodeExtensionOwnership.write(
                token: ownershipToken,
                to: extensionDirectory
            )
            try await runDitto(arguments: ["-c", "-k", expanded.path, output.path])
            return PreparedVSCodeCompanionPackage(
                vsixURL: output,
                workingDirectory: workingDirectory
            )
        } catch {
            try? fileManager.removeItem(at: workingDirectory)
            throw error
        }
    }

    public func remove(_ package: PreparedVSCodeCompanionPackage) {
        try? fileManager.removeItem(at: package.workingDirectory)
    }

    private func runDitto(arguments: [String]) async throws {
        let result = try await processRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: arguments
        )
        guard result.terminationStatus == 0 else {
            throw VSCodeCompanionPackageError.archiveCommandFailed(
                status: result.terminationStatus,
                detail: result.standardError.isEmpty ? result.standardOutput : result.standardError
            )
        }
    }
}

enum VSCodeExtensionOwnership {
    private struct Marker: Codable {
        let token: String
        let contentDigest: String
    }

    private static let fileName = ".oh-my-theme-ownership"

    static func write(token: String, to extensionDirectory: URL) throws {
        let marker = Marker(
            token: token,
            contentDigest: try contentDigest(at: extensionDirectory)
        )
        let data = try JSONEncoder().encode(marker)
        let markerURL = extensionDirectory.appendingPathComponent(fileName)
        let files = ManagedFiles()
        let plan = try files.prepareForConnection(at: markerURL, replacingWith: data)
        _ = try files.apply(plan)
    }

    static func ownershipToken(
        extensionID: String,
        version: String,
        edition: VSCodeEdition,
        homeDirectory: URL
    ) -> String? {
        guard
            let directory = installedExtensionDirectory(
                extensionID: extensionID,
                version: version,
                edition: edition,
                homeDirectory: homeDirectory
            )
        else { return nil }
        let markerURL = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: markerURL),
            let marker = try? JSONDecoder().decode(Marker.self, from: data),
            let currentDigest = try? contentDigest(at: directory),
            currentDigest == marker.contentDigest
        else { return nil }
        return marker.token
    }

    private static func contentDigest(at directory: URL) throws -> String {
        let canonicalDirectory = directory.resolvingSymlinksInPath()
        let markerURL = canonicalDirectory.appendingPathComponent(fileName)
        guard
            let enumerator = FileManager.default.enumerator(
                at: canonicalDirectory,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        else {
            throw VSCodeCompanionPackageError.invalidArchive
        }
        let files = enumerator.compactMap { $0 as? URL }.filter { url in
            let canonicalURL = url.resolvingSymlinksInPath()
            return canonicalURL != markerURL
                && (try? canonicalURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile)
                    == true
        }.map { $0.resolvingSymlinksInPath() }.sorted { $0.path < $1.path }

        var hasher = SHA256()
        for file in files {
            let relativePath = String(file.path.dropFirst(canonicalDirectory.path.count))
            hasher.update(data: Data(relativePath.utf8))
            hasher.update(data: try Data(contentsOf: file, options: .mappedIfSafe))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func installedExtensionDirectory(
        extensionID: String,
        version: String,
        edition: VSCodeEdition,
        homeDirectory: URL
    ) -> URL? {
        let directoryName = edition == .stable ? ".vscode" : ".vscode-insiders"
        let root =
            homeDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return nil }
        let expectedName = "\(extensionID.lowercased())-\(version)"
        return entries.first {
            $0.lastPathComponent.lowercased() == expectedName
        }
    }
}
