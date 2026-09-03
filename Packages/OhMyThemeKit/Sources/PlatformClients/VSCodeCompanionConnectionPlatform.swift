import Foundation

public enum VSCodeTargetScope: String, Codable, Equatable, Sendable {
    case profile
    case window
}

public struct VSCodeRegistrationExpectation: Codable, Equatable, Sendable {
    public let scope: VSCodeTargetScope
    public let edition: VSCodeEdition
    public let applicationVersion: String
    public let extensionVersion: String
    public let profileName: String?
    public let profileID: String?
    public let processID: Int?
    public let windowID: String?

    public init(
        scope: VSCodeTargetScope = .window,
        edition: VSCodeEdition,
        applicationVersion: String,
        extensionVersion: String,
        profileName: String? = nil,
        profileID: String? = nil,
        processID: Int? = nil,
        windowID: String? = nil
    ) {
        self.scope = scope
        self.edition = edition
        self.applicationVersion = applicationVersion
        self.extensionVersion = extensionVersion
        self.profileName = profileName
        self.profileID = profileID
        self.processID = processID
        self.windowID = windowID
    }

    public func matches(_ registration: CompanionRegistration) -> Bool {
        guard registration.vscode.edition == edition.rawValue,
            registration.vscode.version == applicationVersion,
            registration.extensionVersion == extensionVersion,
            registration.capabilities.contains("colorTheme")
        else {
            return false
        }

        let profileMatches: Bool
        if let profileID {
            profileMatches = registration.vscode.profileId == profileID
        } else if let profileName {
            profileMatches = registration.vscode.profileName == profileName
        } else {
            profileMatches = false
        }

        let processOrWindowMatches: Bool
        if let windowID {
            processOrWindowMatches =
                registration.vscode.windowId == windowID
                || registration.vscode.sessionId == windowID
        } else if let processID {
            processOrWindowMatches = registration.vscode.processId == processID
        } else {
            processOrWindowMatches = false
        }

        switch scope {
        case .profile:
            return profileMatches
        case .window:
            return profileMatches && processOrWindowMatches
        }
    }
}

public protocol VSCodeConnectionPlatform: Sendable {
    func discover(selectedBundleURL: URL?) async throws -> VSCodeDiscoveryReport
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
    func registration(matching expectation: VSCodeRegistrationExpectation) async -> CompanionRegistration?
}

/// Production composition for bundle discovery, CLI installation, and matching
/// authenticated registrations from the app-owned companion socket.
public final class SystemVSCodeConnectionPlatform: VSCodeConnectionPlatform, @unchecked Sendable {
    private let discovery: any VSCodeApplicationDiscovering
    private let installer: any VSCodeCompanionInstalling
    private let server: CompanionSocketServer
    private let registrationTimeout: Duration
    private let pollInterval: Duration

    public init(
        discovery: any VSCodeApplicationDiscovering = VSCodeApplicationDiscovery(),
        installer: any VSCodeCompanionInstalling = VSCodeCompanionInstaller(),
        server: CompanionSocketServer,
        registrationTimeout: Duration = .seconds(10),
        pollInterval: Duration = .milliseconds(100)
    ) {
        self.discovery = discovery
        self.installer = installer
        self.server = server
        self.registrationTimeout = registrationTimeout
        self.pollInterval = pollInterval
    }

    public func discover(selectedBundleURL: URL?) async throws -> VSCodeDiscoveryReport {
        try await discovery.discover(selectedBundleURL: selectedBundleURL)
    }

    public func installedCompanion(
        using application: VSCodeInstallation,
        profileName: String,
        extensionID: String
    ) async throws -> VSCodeCompanionInstallation? {
        try await installer.installedCompanion(
            using: application,
            profileName: profileName,
            extensionID: extensionID
        )
    }

    public func install(
        _ artifact: VSCodeCompanionArtifact,
        ownershipToken: String,
        using application: VSCodeInstallation,
        profileName: String
    ) async throws {
        try await installer.install(
            artifact,
            ownershipToken: ownershipToken,
            using: application,
            profileName: profileName
        )
    }

    public func uninstall(
        extensionID: String,
        version: String,
        ownershipToken: String,
        using application: VSCodeInstallation,
        profileName: String
    ) async throws {
        try await installer.uninstall(
            extensionID: extensionID,
            version: version,
            ownershipToken: ownershipToken,
            using: application,
            profileName: profileName
        )
    }

    public func registration(
        matching expectation: VSCodeRegistrationExpectation
    ) async -> CompanionRegistration? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: registrationTimeout)
        repeat {
            if let match = server.registrations().first(where: expectation.matches) {
                return match
            }
            if clock.now >= deadline { return nil }
            try? await Task.sleep(for: pollInterval)
        } while !Task.isCancelled
        return nil
    }
}
