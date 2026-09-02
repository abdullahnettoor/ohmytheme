import CryptoKit
import Foundation
import Persistence
import PlatformClients
import ThemeModel

public enum GhosttyInstallationStatus: String, Codable, Equatable, Sendable {
    case missing
    case supported
    case unsupported
    case ambiguous
}

public enum GhosttyConfigurationStatus: String, Codable, Equatable, Sendable {
    case missing
    case supported
    case unsupported
    case ambiguous
}

public struct GhosttyInstallation: Codable, Equatable, Sendable {
    public let executableURL: URL
    public let version: String

    public init(executableURL: URL, version: String) {
        self.executableURL = executableURL
        self.version = version
    }

    public var isSupported: Bool {
        version.split(separator: ".").prefix(2).map(String.init) == ["1", "3"]
    }
}

public struct GhosttyDiscoveryReport: Codable, Equatable, Sendable {
    public let installations: [GhosttyInstallation]
    public let installationStatus: GhosttyInstallationStatus
    public let configurationCandidates: [URL]
    public let configurationStatus: GhosttyConfigurationStatus
    public let resolvedConfigurationURL: URL?

    public init(
        installations: [GhosttyInstallation],
        configurationCandidates: [URL] = [],
        resolvedConfigurationURL: URL? = nil
    ) {
        self.installations = installations
        if installations.isEmpty {
            installationStatus = .missing
        } else if installations.count > 1 {
            installationStatus = .ambiguous
        } else if installations[0].isSupported {
            installationStatus = .supported
        } else {
            installationStatus = .unsupported
        }
        self.configurationCandidates = configurationCandidates
        self.resolvedConfigurationURL = resolvedConfigurationURL
        if installationStatus == .unsupported {
            configurationStatus = .unsupported
        } else if installationStatus == .ambiguous {
            configurationStatus = .ambiguous
        } else {
            configurationStatus = resolvedConfigurationURL == nil ? .missing : .supported
        }
    }

    public var supportedInstallation: GhosttyInstallation? {
        guard installationStatus == .supported else { return nil }
        return installations.first
    }
}

public struct GhosttyConfigurationLocator: Sendable {
    public let homeDirectory: URL
    public let xdgConfigHome: URL

    public init(homeDirectory: URL, xdgConfigHome: URL? = nil) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.xdgConfigHome =
            (xdgConfigHome ?? homeDirectory.appendingPathComponent(".config"))
            .standardizedFileURL
    }

    public var candidates: [URL] {
        let xdgDirectory = xdgConfigHome.appendingPathComponent("ghostty", isDirectory: true)
        let applicationSupportDirectory =
            homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("com.mitchellh.ghostty", isDirectory: true)
        return [
            xdgDirectory.appendingPathComponent("config"),
            xdgDirectory.appendingPathComponent("config.ghostty"),
            applicationSupportDirectory.appendingPathComponent("config"),
            applicationSupportDirectory.appendingPathComponent("config.ghostty"),
        ]
    }

    public func resolved(using fileManager: FileManager = .default) -> URL? {
        candidates.last(where: { fileManager.fileExists(atPath: $0.path) })
    }

    public var defaultURL: URL {
        candidates.last ?? homeDirectory.appendingPathComponent(".config/ghostty/config.ghostty")
    }
}

public protocol GhosttyRuntime: Sendable {
    func discoverInstallations() async throws -> [GhosttyInstallation]
    func validate(_ input: GhosttyValidationInput) async throws
}

public struct GhosttyValidationInput: Sendable {
    public let executableURL: URL
    public let parentURL: URL
    public let parent: Data
    public let managedArtifactURL: URL
    public let managedArtifact: Data
    public let includedFiles: [URL: Data]

    public init(
        executableURL: URL,
        parentURL: URL,
        parent: Data,
        managedArtifactURL: URL,
        managedArtifact: Data,
        includedFiles: [URL: Data]
    ) {
        self.executableURL = executableURL
        self.parentURL = parentURL
        self.parent = parent
        self.managedArtifactURL = managedArtifactURL
        self.managedArtifact = managedArtifact
        self.includedFiles = includedFiles
    }
}

public final class SystemGhosttyRuntime: GhosttyRuntime, @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func discoverInstallations() async throws -> [GhosttyInstallation] {
        let candidates = Set(
            [
                "/Applications/Ghostty.app/Contents/MacOS/ghostty",
                "\(NSHomeDirectory())/Applications/Ghostty.app/Contents/MacOS/ghostty",
                "/opt/homebrew/bin/ghostty",
                "/usr/local/bin/ghostty",
            ]
                + (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":")
                .map { "\($0)/ghostty" })
        var installations: [GhosttyInstallation] = []
        for path in candidates.sorted() {
            guard fileManager.isExecutableFile(atPath: path) else { continue }
            let executable = URL(fileURLWithPath: path)
            guard let version = try? run(executable: executable, arguments: ["+version"]) else {
                continue
            }
            installations.append(GhosttyInstallation(executableURL: executable, version: version))
        }
        return installations
    }

    public func validate(_ input: GhosttyValidationInput) async throws {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("oh-my-theme-ghostty-validate-\(UUID().uuidString)", isDirectory: true)
        let parentDirectory = directory.appendingPathComponent("config", isDirectory: true)
        let parentURL = parentDirectory.appendingPathComponent("config.ghostty")
        do {
            try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            try stage(input.parent, at: parentURL)
            try stage(input.managedArtifact, at: stagedURL(input.managedArtifactURL, input: input, root: directory))
            for (url, bytes) in input.includedFiles {
                try stage(bytes, at: stagedURL(url, input: input, root: directory))
            }
            _ = try run(
                executable: input.executableURL,
                arguments: ["+validate-config", "--config-file=\(parentURL.path)"]
            )
            try? fileManager.removeItem(at: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw GhosttyRuntimeError.validationFailed(String(describing: error))
        }
    }

    private func stage(_ bytes: Data, at url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: url)
    }

    private func stagedURL(_ url: URL, input: GhosttyValidationInput, root: URL) -> URL {
        let base = input.parentURL.deletingLastPathComponent().standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let stagedBase = root.appendingPathComponent("config", isDirectory: true)
        if path == base {
            return stagedBase
        }
        if path.hasPrefix(base + "/") {
            let relative = String(path.dropFirst(base.count + 1))
            return stagedBase.appendingPathComponent(relative)
        }
        return
            root
            .appendingPathComponent("external", isDirectory: true)
            .appendingPathComponent(url.lastPathComponent)
    }

    private func run(executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw GhosttyRuntimeError.commandFailed(text)
        }
        if arguments == ["+version"],
            let version = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).dropFirst().first
        {
            return String(version)
        }
        return text
    }
}

public enum GhosttyRuntimeError: Error, Equatable, Sendable {
    case commandFailed(String)
    case validationFailed(String)
}

public struct GhosttyConnectionDetails: Codable, Equatable, Sendable {
    public let executableURL: URL
    public let version: String
    public let resolvedConfigURL: URL
    public let resolvedConfigPermissions: UInt16
    public let linkedSourceURL: URL?
    public let includeLine: String
    public let managedArtifactURL: URL
    public let managedArtifactPermissions: UInt16
    public let expectedReload: String

    public init(
        executableURL: URL,
        version: String,
        resolvedConfigURL: URL,
        resolvedConfigPermissions: UInt16,
        linkedSourceURL: URL?,
        includeLine: String,
        managedArtifactURL: URL,
        managedArtifactPermissions: UInt16,
        expectedReload: String
    ) {
        self.executableURL = executableURL
        self.version = version
        self.resolvedConfigURL = resolvedConfigURL
        self.resolvedConfigPermissions = resolvedConfigPermissions
        self.linkedSourceURL = linkedSourceURL
        self.includeLine = includeLine
        self.managedArtifactURL = managedArtifactURL
        self.managedArtifactPermissions = managedArtifactPermissions
        self.expectedReload = expectedReload
    }
}

public struct GhosttyConnectionPayload: Codable, Equatable, Sendable {
    public let details: GhosttyConnectionDetails
    public let parentPlan: ManagedFilePlan
    public let managedArtifactPlan: ManagedFilePlan

    public init(
        details: GhosttyConnectionDetails,
        parentPlan: ManagedFilePlan,
        managedArtifactPlan: ManagedFilePlan
    ) {
        self.details = details
        self.parentPlan = parentPlan
        self.managedArtifactPlan = managedArtifactPlan
    }
}

public struct GhosttyConnectionBaseline: Codable, Equatable, Sendable {
    public let parent: ManagedFileInspection
    public let managedArtifact: ManagedFileInspection

    public init(parent: ManagedFileInspection, managedArtifact: ManagedFileInspection) {
        self.parent = parent
        self.managedArtifact = managedArtifact
    }
}

public struct GhosttyDisconnectPayload: Codable, Equatable, Sendable {
    public let details: GhosttyConnectionDetails
    public let parentAfter: ManagedFileInspection
    public let managedArtifactAfter: ManagedFileInspection

    public init(
        details: GhosttyConnectionDetails,
        parentAfter: ManagedFileInspection,
        managedArtifactAfter: ManagedFileInspection
    ) {
        self.details = details
        self.parentAfter = parentAfter
        self.managedArtifactAfter = managedArtifactAfter
    }
}

public enum GhosttyAdapterError: Error, Equatable, Sendable {
    case installationUnavailable(GhosttyInstallationStatus)
    case configurationUnavailable(GhosttyConfigurationStatus)
    case managedByNix(URL)
    case linkedSourceApprovalRequired
    case malformedPlan
    case staleState
    case validationFailed(String)
    case managedArtifactConflict(URL)
    case restorationConflict
    case themeApplyUnavailable
    case filesystemFailure(String)
}

extension ConnectionPlan {
    public var ghosttyDetails: GhosttyConnectionDetails? {
        guard let opaquePayload,
            let payload = try? JSONDecoder().decode(GhosttyConnectionPayload.self, from: opaquePayload)
        else { return nil }
        return payload.details
    }
}

extension DisconnectPlan {
    public var ghosttyDetails: GhosttyConnectionDetails? {
        guard let opaquePayload,
            let payload = try? JSONDecoder().decode(GhosttyDisconnectPayload.self, from: opaquePayload)
        else { return nil }
        return payload.details
    }
}

public actor GhosttyConfigurationAdapter: WritableThemeAdapter {
    public let id = "ghostty"
    public let version = "1"
    public let payloadVersion = "1"

    private let runtime: any GhosttyRuntime
    private let managedFiles: ManagedFiles
    private let fileManager: FileManager
    private let locator: GhosttyConfigurationLocator
    private let configuredConfigurationURL: URL?
    private let configuredManagedArtifactURL: URL?

    public init(
        runtime: any GhosttyRuntime = SystemGhosttyRuntime(),
        managedFiles: ManagedFiles = ManagedFiles(),
        fileManager: FileManager = .default,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()),
        xdgConfigHome: URL? = nil,
        configurationURL: URL? = nil,
        managedArtifactURL: URL? = nil
    ) {
        self.runtime = runtime
        self.managedFiles = managedFiles
        self.fileManager = fileManager
        locator = GhosttyConfigurationLocator(
            homeDirectory: homeDirectory,
            xdgConfigHome: xdgConfigHome
        )
        configuredConfigurationURL = configurationURL?.standardizedFileURL
        configuredManagedArtifactURL = managedArtifactURL?.standardizedFileURL
    }

    public func discover() async throws -> GhosttyDiscoveryReport {
        let installations = try await runtime.discoverInstallations()
        let resolved = configuredConfigurationURL ?? locator.resolved(using: fileManager)
        return GhosttyDiscoveryReport(
            installations: installations,
            configurationCandidates: locator.candidates.filter {
                fileManager.fileExists(atPath: $0.path)
            },
            resolvedConfigurationURL: resolved
        )
    }

    public func prepareConnection(
        instance: ConnectedTargetInstance,
        approveLinkedSource: Bool = false
    ) async throws -> ConnectionPlan {
        let report = try await discover()
        guard let installation = report.supportedInstallation else {
            throw GhosttyAdapterError.installationUnavailable(report.installationStatus)
        }
        let requestedURL = (configuredConfigurationURL ?? report.resolvedConfigurationURL ?? locator.defaultURL)
            .standardizedFileURL
        let parentInspection = try managedFiles.inspect(at: requestedURL)
        if case .managedByNix = parentInspection.ownership {
            throw GhosttyAdapterError.managedByNix(parentInspection.resolvedURL)
        }
        let artifactURL =
            configuredManagedArtifactURL
            ?? parentInspection.resolvedURL.deletingLastPathComponent()
            .appendingPathComponent("oh-my-theme", isDirectory: true)
            .appendingPathComponent("config.ghostty")
        let includeLine = "config-file = ?oh-my-theme/config.ghostty"
        let parentBytes = parentBytesWithInclude(
            existing: parentInspection.snapshot.bytes ?? Data(),
            lineEnding: parentInspection.snapshot.lineEnding,
            includeLine: includeLine
        )
        let parentPlan = try managedFiles.prepareForConnection(
            at: requestedURL,
            replacingWith: parentBytes,
            approveLinkedSource: approveLinkedSource
        )
        let artifactInspection = try managedFiles.inspect(at: artifactURL)
        let initialArtifact = Data("# Managed by Oh My Theme\n".utf8)
        switch artifactInspection.ownership {
        case .managedByNix:
            throw GhosttyAdapterError.managedByNix(artifactInspection.resolvedURL)
        case .linkedUserOwned:
            throw GhosttyAdapterError.managedArtifactConflict(artifactInspection.resolvedURL)
        case .userOwned:
            break
        }
        if let existing = artifactInspection.snapshot.bytes, existing != initialArtifact {
            throw GhosttyAdapterError.managedArtifactConflict(artifactInspection.resolvedURL)
        }
        let artifactPlan = try managedFiles.prepareForConnection(
            at: artifactURL,
            replacingWith: initialArtifact,
            approveLinkedSource: true
        )
        let details = GhosttyConnectionDetails(
            executableURL: installation.executableURL,
            version: installation.version,
            resolvedConfigURL: parentInspection.resolvedURL,
            resolvedConfigPermissions: parentInspection.snapshot.metadata?.permissions ?? 0o600,
            linkedSourceURL: linkedSourceURL(from: parentInspection.ownership),
            includeLine: includeLine,
            managedArtifactURL: artifactPlan.resolvedURL,
            managedArtifactPermissions: artifactInspection.snapshot.metadata?.permissions ?? 0o600,
            expectedReload: "Press cmd+shift+,"
        )
        let payload = GhosttyConnectionPayload(
            details: details,
            parentPlan: parentPlan,
            managedArtifactPlan: artifactPlan
        )
        let baseline = GhosttyConnectionBaseline(
            parent: parentInspection,
            managedArtifact: artifactInspection
        )
        return ConnectionPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            capturedPreChangeState: try encode(baseline),
            intendedChangeDigest: digest(of: parentPlan.intendedBytes + artifactPlan.intendedBytes),
            staleStateToken: digest(of: Data("\(parentPlan.staleStateToken)|\(artifactPlan.staleStateToken)".utf8)),
            expectedSideEffects: [
                "Ghostty: managed include and fragment",
                "Ghostty: configuration reload required",
            ],
            requiredPermissions: ["Write the selected user-owned Ghostty configuration"],
            userActions: [
                UserAction(title: "Reload Ghostty", detail: details.expectedReload)
            ]
                + (details.linkedSourceURL == nil || approveLinkedSource
                    ? []
                    : [
                        UserAction(
                            title: "Approve dotfiles source",
                            detail: "Oh My Theme will edit \(details.linkedSourceURL?.path ?? "the linked source")."
                        )
                    ]),
            opaquePayload: try encode(payload),
            requiresApproval: details.linkedSourceURL != nil && !approveLinkedSource
        )
    }

    public func connect(_ plan: ConnectionPlan) async throws -> ConnectionReceipt {
        let payload = try connectionPayload(from: plan)
        guard !plan.requiresApproval else {
            throw GhosttyAdapterError.linkedSourceApprovalRequired
        }
        try await revalidateConnection(plan: plan)
        do {
            let includedFiles = try includeGraph(
                from: payload.parentPlan.resolvedURL,
                bytes: payload.parentPlan.intendedBytes,
                replacing: payload.managedArtifactPlan.resolvedURL,
                visited: []
            )
            try await runtime.validate(
                GhosttyValidationInput(
                    executableURL: payload.details.executableURL,
                    parentURL: payload.parentPlan.resolvedURL,
                    parent: payload.parentPlan.intendedBytes,
                    managedArtifactURL: payload.managedArtifactPlan.resolvedURL,
                    managedArtifact: payload.managedArtifactPlan.intendedBytes,
                    includedFiles: includedFiles
                ))
        } catch let error as GhosttyRuntimeError {
            throw GhosttyAdapterError.validationFailed(String(describing: error))
        } catch {
            throw GhosttyAdapterError.validationFailed(String(describing: error))
        }

        let artifactDirectory = payload.managedArtifactPlan.resolvedURL.deletingLastPathComponent()
        let createdDirectory = !fileManager.fileExists(atPath: artifactDirectory.path)
        if createdDirectory {
            do {
                try fileManager.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: artifactDirectory.path)
            } catch {
                throw GhosttyAdapterError.filesystemFailure(String(describing: error))
            }
        }

        var parentReceipt: ManagedFileReceipt?
        var artifactReceipt: ManagedFileReceipt?
        do {
            parentReceipt = try managedFiles.apply(payload.parentPlan)
            artifactReceipt = try managedFiles.apply(payload.managedArtifactPlan)
        } catch {
            if let parentReceipt {
                try? managedFiles.rollback(parentReceipt)
            }
            if createdDirectory {
                try? fileManager.removeItem(at: artifactDirectory)
            }
            throw GhosttyAdapterError.filesystemFailure(String(describing: error))
        }
        let changed = parentReceipt?.changed == true || artifactReceipt?.changed == true
        return ConnectionReceipt(
            configurationState: changed ? .updated : .unchanged,
            runningInstanceReach: .reloadRequired,
            detail: "Ghostty connected; reload required with cmd+shift+,"
        )
    }

    public func revalidateConnection(plan: ConnectionPlan) async throws {
        let payload = try connectionPayload(from: plan)
        guard plan.adapterID == id, plan.adapterVersion == version else {
            throw GhosttyAdapterError.malformedPlan
        }
        try revalidate(filePlan: payload.parentPlan)
        try revalidate(filePlan: payload.managedArtifactPlan)
    }

    public func classifyConnection(plan: ConnectionPlan) async throws -> ReconciliationClassification {
        let payload = try connectionPayload(from: plan)
        let baseline = try decode(GhosttyConnectionBaseline.self, from: plan.capturedPreChangeState)
        let currentParent = try managedFiles.inspect(at: payload.parentPlan.requestedURL)
        let currentArtifact = try managedFiles.inspect(at: payload.managedArtifactPlan.requestedURL)
        if currentParent == baseline.parent, currentArtifact == baseline.managedArtifact {
            return .beforeChange
        }
        if matches(currentParent, payload.parentPlan), matches(currentArtifact, payload.managedArtifactPlan) {
            return .intendedAfterChange
        }
        return .conflicting
    }

    public func restoreConnection(
        instance: ConnectedTargetInstance,
        baseline: Data
    ) async throws -> ConnectionReceipt {
        let saved = try decode(GhosttyConnectionBaseline.self, from: baseline)
        let currentParent = try managedFiles.inspect(at: saved.parent.requestedURL)
        let currentArtifact = try managedFiles.inspect(at: saved.managedArtifact.requestedURL)
        let expectedParent = parentBytesWithInclude(
            existing: saved.parent.snapshot.bytes ?? Data(),
            lineEnding: saved.parent.snapshot.lineEnding,
            includeLine: "config-file = ?oh-my-theme/config.ghostty"
        )
        guard currentParent.resolvedURL == saved.parent.resolvedURL,
            currentArtifact.resolvedURL == saved.managedArtifact.resolvedURL,
            currentParent.snapshot.bytes == expectedParent,
            currentParent.snapshot.metadata == saved.parent.snapshot.metadata,
            currentArtifact.snapshot.bytes == Data("# Managed by Oh My Theme\n".utf8),
            expectedArtifactMetadata(current: currentArtifact, baseline: saved.managedArtifact)
        else {
            throw GhosttyAdapterError.restorationConflict
        }
        try restore(before: saved.parent, after: currentParent)
        try restore(before: saved.managedArtifact, after: currentArtifact)
        return ConnectionReceipt(
            configurationState: .updated,
            runningInstanceReach: .reloadRequired,
            detail: "Ghostty restored; reload required with cmd+shift+,"
        )
    }

    public func prepareDisconnect(
        instance: ConnectedTargetInstance,
        baseline: StoredConnectionBaseline,
        baselineData: Data
    ) async throws -> DisconnectPlan {
        let report = try await discover()
        guard report.installationStatus == .supported,
            let installation = report.supportedInstallation
        else {
            throw GhosttyAdapterError.installationUnavailable(report.installationStatus)
        }
        let requestedURL = (configuredConfigurationURL ?? report.resolvedConfigurationURL ?? locator.defaultURL)
            .standardizedFileURL
        let parent = try managedFiles.inspect(at: requestedURL)
        let artifactURL =
            configuredManagedArtifactURL
            ?? parent.resolvedURL.deletingLastPathComponent()
            .appendingPathComponent("oh-my-theme", isDirectory: true)
            .appendingPathComponent("config.ghostty")
        let artifact = try managedFiles.inspect(at: artifactURL)
        let saved = try decode(GhosttyConnectionBaseline.self, from: baselineData)
        let expectedParent = parentBytesWithInclude(
            existing: saved.parent.snapshot.bytes ?? Data(),
            lineEnding: saved.parent.snapshot.lineEnding,
            includeLine: "config-file = ?oh-my-theme/config.ghostty"
        )
        guard parent.resolvedURL == saved.parent.resolvedURL,
            artifact.resolvedURL == saved.managedArtifact.resolvedURL,
            parent.snapshot.bytes == expectedParent,
            parent.snapshot.metadata == saved.parent.snapshot.metadata,
            artifact.snapshot.bytes == Data("# Managed by Oh My Theme\n".utf8),
            expectedArtifactMetadata(current: artifact, baseline: saved.managedArtifact)
        else {
            throw GhosttyAdapterError.restorationConflict
        }
        let details = GhosttyConnectionDetails(
            executableURL: installation.executableURL,
            version: installation.version,
            resolvedConfigURL: parent.resolvedURL,
            resolvedConfigPermissions: parent.snapshot.metadata?.permissions ?? 0o600,
            linkedSourceURL: linkedSourceURL(from: parent.ownership),
            includeLine: "config-file = ?oh-my-theme/config.ghostty",
            managedArtifactURL: artifact.resolvedURL,
            managedArtifactPermissions: artifact.snapshot.metadata?.permissions ?? 0o600,
            expectedReload: "Press cmd+shift+,"
        )
        let payload = GhosttyDisconnectPayload(
            details: details,
            parentAfter: parent,
            managedArtifactAfter: artifact
        )
        return DisconnectPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            baselineReference: baseline.baselineReference,
            staleStateToken: digest(
                of: Data("\(parent.snapshot.staleStateToken)|\(artifact.snapshot.staleStateToken)".utf8)),
            opaquePayload: try encode(payload)
        )
    }

    public func disconnect(_ plan: DisconnectPlan, baseline: Data) async throws -> AdapterReceipt {
        let payload = try disconnectPayload(from: plan)
        try await revalidateDisconnect(plan: plan)
        let saved = try decode(GhosttyConnectionBaseline.self, from: baseline)
        do {
            try restore(before: saved.parent, after: payload.parentAfter)
            try restore(before: saved.managedArtifact, after: payload.managedArtifactAfter)
        } catch {
            throw GhosttyAdapterError.filesystemFailure(String(describing: error))
        }
        return AdapterReceipt(
            configurationState: .updated,
            runningInstanceReach: .reloadRequired,
            detail: "Ghostty disconnected; reload required with cmd+shift+,"
        )
    }

    public func revalidateDisconnect(plan: DisconnectPlan) async throws {
        let payload = try disconnectPayload(from: plan)
        try revalidate(current: payload.parentAfter, at: payload.parentAfter.requestedURL)
        try revalidate(current: payload.managedArtifactAfter, at: payload.managedArtifactAfter.requestedURL)
    }

    public func classifyDisconnect(plan: DisconnectPlan) async throws -> ReconciliationClassification {
        let payload = try disconnectPayload(from: plan)
        let currentParent = try managedFiles.inspect(at: payload.parentAfter.requestedURL)
        let currentArtifact = try managedFiles.inspect(at: payload.managedArtifactAfter.requestedURL)
        return matches(currentParent, payload.parentAfter) && matches(currentArtifact, payload.managedArtifactAfter)
            ? .beforeChange
            : .conflicting
    }

    public func prepareApply(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme
    ) async throws -> AdapterPlan {
        throw GhosttyAdapterError.themeApplyUnavailable
    }

    public func apply(_ plan: AdapterPlan) async throws -> AdapterReceipt {
        throw GhosttyAdapterError.themeApplyUnavailable
    }

    public func revalidateApply(plan: AdapterPlan) async throws {
        throw GhosttyAdapterError.themeApplyUnavailable
    }

    public func classifyApply(plan: AdapterPlan) async throws -> ReconciliationClassification {
        throw GhosttyAdapterError.themeApplyUnavailable
    }

    public func rollbackApply(plan: AdapterPlan, receipt: AdapterReceipt) async throws {
        throw GhosttyAdapterError.themeApplyUnavailable
    }

    private func connectionPayload(from plan: ConnectionPlan) throws -> GhosttyConnectionPayload {
        guard let data = plan.opaquePayload else { throw GhosttyAdapterError.malformedPlan }
        return try decode(GhosttyConnectionPayload.self, from: data)
    }

    private func disconnectPayload(from plan: DisconnectPlan) throws -> GhosttyDisconnectPayload {
        guard let data = plan.opaquePayload else { throw GhosttyAdapterError.malformedPlan }
        return try decode(GhosttyDisconnectPayload.self, from: data)
    }

    private func revalidate(filePlan: ManagedFilePlan) throws {
        let current = try managedFiles.inspect(at: filePlan.requestedURL)
        guard current.resolvedURL == filePlan.resolvedURL,
            current.snapshot.staleStateToken == filePlan.staleStateToken
        else { throw GhosttyAdapterError.staleState }
    }

    private func revalidate(current: ManagedFileInspection, at url: URL) throws {
        let latest = try managedFiles.inspect(at: url)
        guard latest == current else { throw GhosttyAdapterError.staleState }
    }

    private func restore(before: ManagedFileInspection, after: ManagedFileInspection) throws {
        try managedFiles.rollback(
            ManagedFileReceipt(
                planID: UUID(),
                before: before,
                after: after,
                changed: true
            )
        )
    }

    private func matches(_ inspection: ManagedFileInspection, _ plan: ManagedFilePlan) -> Bool {
        inspection.resolvedURL == plan.resolvedURL && inspection.snapshot.digest == plan.intendedDigest
            && expectedMetadataMatches(
                current: inspection.snapshot.metadata,
                before: plan.inspection.snapshot.metadata,
                intendedBytes: plan.intendedBytes
            )
    }

    private func matches(_ current: ManagedFileInspection, _ expected: ManagedFileInspection) -> Bool {
        current == expected
    }

    private func linkedSourceURL(from ownership: ManagedFileOwnership) -> URL? {
        guard case .linkedUserOwned(let path) = ownership else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func includeGraph(
        from url: URL,
        bytes: Data,
        replacing managedArtifactURL: URL,
        visited: Set<URL>
    ) throws -> [URL: Data] {
        let canonicalURL = url.standardizedFileURL
        guard !visited.contains(canonicalURL) else { return [:] }
        var visited = visited
        visited.insert(canonicalURL)
        let text = String(decoding: bytes, as: UTF8.self)
        var result: [URL: Data] = [:]
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, parts[0] == "config-file" else { continue }
            var path = parts[1]
            if path.first == "?" { path.removeFirst() }
            guard !path.isEmpty else { continue }
            let includedURL =
                path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : canonicalURL.deletingLastPathComponent().appendingPathComponent(path)
            let standardizedURL = includedURL.standardizedFileURL
            guard standardizedURL != managedArtifactURL.standardizedFileURL,
                fileManager.fileExists(atPath: standardizedURL.path)
            else { continue }
            let includedBytes = try Data(contentsOf: standardizedURL)
            result[standardizedURL] = includedBytes
            result.merge(
                try includeGraph(
                    from: standardizedURL,
                    bytes: includedBytes,
                    replacing: managedArtifactURL,
                    visited: visited
                ),
                uniquingKeysWith: { current, _ in current }
            )
            visited.insert(standardizedURL)
        }
        return result
    }

    private func expectedArtifactMetadata(
        current: ManagedFileInspection,
        baseline: ManagedFileInspection
    ) -> Bool {
        guard let metadata = current.snapshot.metadata else { return false }
        if let baselineMetadata = baseline.snapshot.metadata {
            return metadata == baselineMetadata
        }
        return metadata.permissions == 0o600 && metadata.flags == 0
            && metadata.extendedAttributes.keys.allSatisfy { $0 == "com.apple.provenance" }
            && metadata.accessControlList == nil && metadata.lineEnding == .lf
    }

    private func expectedMetadataMatches(
        current: ManagedFileMetadata?,
        before: ManagedFileMetadata?,
        intendedBytes: Data
    ) -> Bool {
        guard let current else { return false }
        if let before {
            return current == before
        }
        return current.permissions == 0o600 && current.flags == 0
            && current.extendedAttributes.keys.allSatisfy { $0 == "com.apple.provenance" }
            && current.accessControlList == nil && current.lineEnding != .none && !intendedBytes.isEmpty
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    private func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func parentBytesWithInclude(
        existing: Data,
        lineEnding: ManagedFileLineEnding,
        includeLine: String
    ) -> Data {
        let existingText = String(decoding: existing, as: UTF8.self)
        let hasInclude =
            existingText
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .contains { $0.trimmingCharacters(in: .whitespaces) == includeLine }
        guard !hasInclude else { return existing }
        let delimiter: Data
        switch lineEnding {
        case .crlf: delimiter = Data([0x0D, 0x0A])
        case .cr: delimiter = Data([0x0D])
        case .lf, .mixed, .none: delimiter = Data([0x0A])
        }
        var result = existing
        if !result.isEmpty, !Data(result.suffix(delimiter.count)).elementsEqual(delimiter) {
            result.append(delimiter)
        }
        result.append(Data(includeLine.utf8))
        result.append(delimiter)
        return result
    }
}
