import CryptoKit
import Foundation
import Testing

@testable import PlatformClients

@Suite("VS Code companion installer (issue #19)")
struct VSCodeCompanionInstallerTests {
    @Test("The pinned companion is inspected and installed through the selected bundle executable")
    func usesSelectedBundleExecutable() async throws {
        let fixture = try InstallerFixture()
        let process = RecordingProcessRunner(results: [
            ProcessResult(terminationStatus: 0, standardOutput: "other.extension@1.0.0\n", standardError: ""),
            ProcessResult(terminationStatus: 0, standardOutput: "Extension installed.\n", standardError: ""),
            ProcessResult(
                terminationStatus: 0,
                standardOutput: "ohmytheme.oh-my-theme-companion@0.1.0\n",
                standardError: ""
            ),
        ])
        let installer = VSCodeCompanionInstaller(
            processRunner: process,
            packagePreparer: RecordingPackagePreparer(
                extensionDirectory: fixture.extensionDirectory
            ),
            homeDirectory: fixture.directory
        )

        let before = try await installer.installedCompanion(
            using: fixture.installation,
            profileName: "Default",
            extensionID: fixture.artifact.extensionID
        )
        try await installer.install(
            fixture.artifact,
            ownershipToken: "ownership-1",
            using: fixture.installation,
            profileName: "Default"
        )

        #expect(before == nil)
        let installed = try await installer.installedCompanion(
            using: fixture.installation,
            profileName: "Default",
            extensionID: fixture.artifact.extensionID
        )
        #expect(installed?.ownershipToken == "ownership-1")
        try Data("external replacement".utf8).write(
            to: fixture.extensionDirectory.appendingPathComponent("package.json")
        )
        await #expect(throws: VSCodeCompanionInstallerError.ownershipMismatch) {
            try await installer.uninstall(
                extensionID: fixture.artifact.extensionID,
                version: fixture.artifact.version,
                ownershipToken: "ownership-1",
                using: fixture.installation,
                profileName: "Default"
            )
        }
        #expect(
            await process.calls == [
                ProcessCall(
                    executableURL: fixture.installation.executableURL,
                    arguments: ["--profile", "Default", "--list-extensions", "--show-versions"]
                ),
                ProcessCall(
                    executableURL: fixture.installation.executableURL,
                    arguments: [
                        "--profile", "Default", "--install-extension", fixture.artifact.vsixURL.path, "--force",
                    ]
                ),
                ProcessCall(
                    executableURL: fixture.installation.executableURL,
                    arguments: ["--profile", "Default", "--list-extensions", "--show-versions"]
                ),
            ])
    }

    @Test("The selected bundle executable must match the discovered content")
    func rejectsChangedSelectedBundleExecutable() async throws {
        let fixture = try InstallerFixture()
        try Data("#!/bin/sh\necho replaced\n".utf8).write(
            to: fixture.installation.executableURL
        )
        let installer = VSCodeCompanionInstaller(
            processRunner: RecordingProcessRunner(results: []),
            homeDirectory: fixture.directory
        )

        await #expect(
            throws: VSCodeCompanionInstallerError.invalidApplicationExecutable(
                fixture.installation.executableURL
            )
        ) {
            _ = try await installer.installedCompanion(
                using: fixture.installation,
                profileName: "Default",
                extensionID: fixture.artifact.extensionID
            )
        }
    }

    @Test("The package preparer embeds ownership in the VSIX before installation")
    func packageContainsOwnershipMarker() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-owned-vsix-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let extensionDirectory = source.appendingPathComponent("extension", isDirectory: true)
        let archive = root.appendingPathComponent("base.vsix")
        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: extensionDirectory.appendingPathComponent("package.json"))
        let runner = ProcessRunner()
        let created = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", source.path, archive.path]
        )
        #expect(created.terminationStatus == 0)
        let bytes = try Data(contentsOf: archive)
        let artifact = VSCodeCompanionArtifact(
            extensionID: "ohmytheme.oh-my-theme-companion",
            version: "0.1.0",
            vsixURL: archive,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        )
        let preparer = VSCodeCompanionPackagePreparer()

        let prepared = try await preparer.prepare(artifact, ownershipToken: "owner-1")
        defer { preparer.remove(prepared) }
        let extracted = try await runner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", prepared.vsixURL.path, unpacked.path]
        )

        #expect(extracted.terminationStatus == 0)
        #expect(
            FileManager.default.fileExists(
                atPath: unpacked.appendingPathComponent("extension/.oh-my-theme-ownership").path
            )
        )
    }

    @Test("Registration matching distinguishes durable profiles from individual windows")
    func registrationMatchingUsesRequestedTargetScope() {
        let registration = CompanionRegistration(
            serverSessionID: "server-1",
            extensionVersion: "0.1.0",
            vscode: CompanionVSCodeIdentity(
                edition: "vscode",
                version: "1.95.2",
                profileName: "",
                profileId: "profile-1",
                machineId: "machine-1",
                sessionId: "window-1",
                processId: 42,
                windowId: "window-1"
            ),
            capabilities: ["colorTheme"],
            currentSettings: [:]
        )
        let complete = VSCodeRegistrationExpectation(
            edition: .stable,
            applicationVersion: "1.95.2",
            extensionVersion: "0.1.0",
            profileID: "profile-1",
            windowID: "window-1"
        )
        let profileOnly = VSCodeRegistrationExpectation(
            edition: .stable,
            applicationVersion: "1.95.2",
            extensionVersion: "0.1.0",
            profileID: "profile-1"
        )

        let durableProfile = VSCodeRegistrationExpectation(
            scope: .profile,
            edition: .stable,
            applicationVersion: "1.95.2",
            extensionVersion: "0.1.0",
            profileID: "profile-1"
        )

        #expect(complete.matches(registration))
        #expect(!profileOnly.matches(registration))
        #expect(durableProfile.matches(registration))
    }
}

private struct InstallerFixture {
    let directory: URL
    let installation: VSCodeInstallation
    let artifact: VSCodeCompanionArtifact
    let extensionDirectory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-vscode-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("Visual Studio Code.app/Contents/Resources/app/bin/code")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let executableBytes = Data("#!/bin/sh\n".utf8)
        try executableBytes.write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let executableAttributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        let executableIdentity = ManagedFileIdentity(
            device: try #require((executableAttributes[.systemNumber] as? NSNumber)?.uint64Value),
            inode: try #require((executableAttributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        )
        let executableDigest = SHA256.hash(data: executableBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        extensionDirectory =
            directory
            .appendingPathComponent(".vscode/extensions", isDirectory: true)
            .appendingPathComponent("ohmytheme.oh-my-theme-companion-0.1.0", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extensionDirectory,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: extensionDirectory.appendingPathComponent("package.json")
        )
        let vsix = directory.appendingPathComponent("oh-my-theme-companion-0.1.0.vsix")
        let bytes = Data("pinned companion".utf8)
        try bytes.write(to: vsix)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        installation = VSCodeInstallation(
            bundleURL: directory.appendingPathComponent("Visual Studio Code.app"),
            bundleIdentifier: VSCodeEdition.stable.bundleIdentifier,
            edition: .stable,
            version: "1.95.2",
            executableURL: executable,
            executableIdentity: executableIdentity,
            executableSHA256: executableDigest
        )
        artifact = VSCodeCompanionArtifact(
            extensionID: "ohmytheme.oh-my-theme-companion",
            version: "0.1.0",
            vsixURL: vsix,
            sha256: digest
        )
    }
}

private final class RecordingPackagePreparer: VSCodeCompanionPackagePreparing,
    @unchecked Sendable
{
    private let extensionDirectory: URL

    init(extensionDirectory: URL) {
        self.extensionDirectory = extensionDirectory
    }

    func prepare(
        _ artifact: VSCodeCompanionArtifact,
        ownershipToken: String
    ) async throws -> PreparedVSCodeCompanionPackage {
        try VSCodeExtensionOwnership.write(
            token: ownershipToken,
            to: extensionDirectory
        )
        return PreparedVSCodeCompanionPackage(
            vsixURL: artifact.vsixURL,
            workingDirectory: artifact.vsixURL.deletingLastPathComponent()
        )
    }

    func remove(_ package: PreparedVSCodeCompanionPackage) {}
}

private actor RecordingProcessRunner: ProcessRunning {
    private var queuedResults: [ProcessResult]
    private(set) var calls: [ProcessCall] = []

    init(results: [ProcessResult]) {
        queuedResults = results
    }

    func run(executableURL: URL, arguments: [String]) async throws -> ProcessResult {
        calls.append(ProcessCall(executableURL: executableURL, arguments: arguments))
        return queuedResults.removeFirst()
    }
}
