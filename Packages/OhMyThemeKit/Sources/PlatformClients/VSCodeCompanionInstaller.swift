import CryptoKit
import Foundation

public struct VSCodeCompanionArtifact: Codable, Equatable, Sendable {
    public let extensionID: String
    public let version: String
    public let vsixURL: URL
    public let sha256: String

    public init(extensionID: String, version: String, vsixURL: URL, sha256: String) {
        self.extensionID = extensionID
        self.version = version
        self.vsixURL = vsixURL.standardizedFileURL
        self.sha256 = sha256.lowercased()
    }
}

public struct VSCodeCompanionInstallation: Codable, Equatable, Sendable {
    public let extensionID: String
    public let version: String
    public let ownershipToken: String?

    public init(extensionID: String, version: String, ownershipToken: String? = nil) {
        self.extensionID = extensionID
        self.version = version
        self.ownershipToken = ownershipToken
    }
}

public enum VSCodeCompanionInstallerError: Error, Equatable, Sendable {
    case invalidApplicationExecutable(URL)
    case artifactUnavailable(URL)
    case artifactDigestMismatch(expected: String, observed: String)
    case installedExtensionDirectoryUnavailable(String)
    case ownershipMismatch
    case commandFailed(status: Int32, detail: String)
}

public protocol VSCodeCompanionInstalling: Sendable {
    func installedCompanion(
        using application: VSCodeInstallation,
        profileName: String,
        extensionID: String
    ) async throws -> VSCodeCompanionInstallation?

    func install(
        _ artifact: VSCodeCompanionArtifact,
        ownershipToken: String,
        using application: VSCodeInstallation,
        profileName: String
    ) async throws

    func uninstall(
        extensionID: String,
        version: String,
        ownershipToken: String,
        using application: VSCodeInstallation,
        profileName: String
    ) async throws
}

/// Owns the documented VS Code CLI setup route. Every operation invokes the
/// executable inside the application bundle chosen during discovery; no command
/// is resolved from `PATH`.
public struct VSCodeCompanionInstaller: VSCodeCompanionInstalling, Sendable {
    private let processRunner: any ProcessRunning
    private let packagePreparer: any VSCodeCompanionPackagePreparing
    private let homeDirectory: URL

    public init(
        processRunner: any ProcessRunning = ProcessRunner(),
        packagePreparer: any VSCodeCompanionPackagePreparing = VSCodeCompanionPackagePreparer(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.processRunner = processRunner
        self.packagePreparer = packagePreparer
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public func installedCompanion(
        using application: VSCodeInstallation,
        profileName: String,
        extensionID: String
    ) async throws -> VSCodeCompanionInstallation? {
        try validate(application)
        let result = try await processRunner.run(
            executableURL: application.executableURL,
            arguments: ["--profile", profileName, "--list-extensions", "--show-versions"]
        )
        try validate(result)
        let expectedID = extensionID.lowercased()
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "@", maxSplits: 1).map(String.init)
            guard fields.count == 2, fields[0].lowercased() == expectedID else { continue }
            return VSCodeCompanionInstallation(
                extensionID: fields[0],
                version: fields[1],
                ownershipToken: VSCodeExtensionOwnership.ownershipToken(
                    extensionID: fields[0],
                    version: fields[1],
                    edition: application.edition,
                    homeDirectory: homeDirectory
                )
            )
        }
        return nil
    }

    public func install(
        _ artifact: VSCodeCompanionArtifact,
        ownershipToken: String,
        using application: VSCodeInstallation,
        profileName: String
    ) async throws {
        try validate(application)
        let observed = try artifactDigest(at: artifact.vsixURL)
        guard observed == artifact.sha256 else {
            throw VSCodeCompanionInstallerError.artifactDigestMismatch(
                expected: artifact.sha256,
                observed: observed
            )
        }
        let prepared = try await packagePreparer.prepare(
            artifact,
            ownershipToken: ownershipToken
        )
        defer { packagePreparer.remove(prepared) }
        let result = try await processRunner.run(
            executableURL: application.executableURL,
            arguments: [
                "--profile", profileName,
                "--install-extension", prepared.vsixURL.path,
                "--force",
            ]
        )
        try validate(result)
    }

    public func uninstall(
        extensionID: String,
        version: String,
        ownershipToken: String,
        using application: VSCodeInstallation,
        profileName: String
    ) async throws {
        try validate(application)
        guard
            VSCodeExtensionOwnership.ownershipToken(
                extensionID: extensionID,
                version: version,
                edition: application.edition,
                homeDirectory: homeDirectory
            ) == ownershipToken
        else {
            throw VSCodeCompanionInstallerError.ownershipMismatch
        }
        let result = try await processRunner.run(
            executableURL: application.executableURL,
            arguments: [
                "--profile", profileName,
                "--uninstall-extension", extensionID,
            ]
        )
        try validate(result)
    }

    private func validate(_ application: VSCodeInstallation) throws {
        let expected = application.bundleURL.appendingPathComponent(
            "Contents/Resources/app/bin/\(application.edition.cliName)"
        ).standardizedFileURL
        guard application.executableURL.standardizedFileURL == expected else {
            throw VSCodeCompanionInstallerError.invalidApplicationExecutable(
                application.executableURL
            )
        }
        guard
            FileManager.default.isExecutableFile(atPath: application.executableURL.path),
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: application.executableURL.path
            ),
            let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            ManagedFileIdentity(device: device, inode: inode) == application.executableIdentity,
            let executableData = try? Data(
                contentsOf: application.executableURL,
                options: .mappedIfSafe
            ),
            SHA256.hash(data: executableData)
                .map({ String(format: "%02x", $0) })
                .joined() == application.executableSHA256.lowercased()
        else {
            throw VSCodeCompanionInstallerError.invalidApplicationExecutable(
                application.executableURL
            )
        }
    }

    private func validate(_ result: ProcessResult) throws {
        guard result.terminationStatus == 0 else {
            let detail =
                result.standardError.isEmpty
                ? result.standardOutput
                : result.standardError
            throw VSCodeCompanionInstallerError.commandFailed(
                status: result.terminationStatus,
                detail: detail
            )
        }
    }

    private func artifactDigest(at url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw VSCodeCompanionInstallerError.artifactUnavailable(url)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

}
