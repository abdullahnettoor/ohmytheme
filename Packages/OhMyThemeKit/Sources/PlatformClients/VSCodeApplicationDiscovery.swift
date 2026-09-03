import AppKit
import CryptoKit
import Foundation

public enum VSCodeEdition: String, Codable, CaseIterable, Equatable, Sendable {
    case stable = "vscode"
    case insiders

    public var displayName: String {
        switch self {
        case .stable: "Visual Studio Code"
        case .insiders: "Visual Studio Code - Insiders"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .stable: "com.microsoft.VSCode"
        case .insiders: "com.microsoft.VSCodeInsiders"
        }
    }

    /// Both Microsoft macOS bundles ship the documented CLI script as
    /// `Contents/Resources/app/bin/code`; `code-insiders` is the optional
    /// shell command installed outside the bundle.
    public var cliName: String { "code" }
}

public struct VSCodeInstallation: Codable, Equatable, Sendable {
    public let bundleURL: URL
    public let bundleIdentifier: String
    public let edition: VSCodeEdition
    public let version: String
    public let executableURL: URL
    public let executableIdentity: ManagedFileIdentity
    public let executableSHA256: String

    public init(
        bundleURL: URL,
        bundleIdentifier: String,
        edition: VSCodeEdition,
        version: String,
        executableURL: URL,
        executableIdentity: ManagedFileIdentity,
        executableSHA256: String
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.bundleIdentifier = bundleIdentifier
        self.edition = edition
        self.version = version
        self.executableURL = executableURL.standardizedFileURL
        self.executableIdentity = executableIdentity
        self.executableSHA256 = executableSHA256
    }

    /// The pinned companion declares VS Code `^1.90.0`, which means any
    /// standard 1.x Stable or Insiders build from 1.90 onward.
    public var isSupported: Bool {
        guard let components = Self.versionComponents(version) else { return false }
        return components.major == 1 && components.minor >= 90
    }

    private static func versionComponents(_ version: String) -> (major: Int, minor: Int)? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
            let major = Int(parts[0]),
            let minor = Int(parts[1])
        else {
            return nil
        }
        return (major, minor)
    }
}

public enum VSCodeDiscoveryStatus: String, Codable, Equatable, Sendable {
    case missing
    case supported
    case unsupported
    case ambiguous
}

public struct VSCodeDiscoveryReport: Codable, Equatable, Sendable {
    public let installations: [VSCodeInstallation]
    public let status: VSCodeDiscoveryStatus
    public let selectedInstallation: VSCodeInstallation?
    public let detail: String?

    public init(
        installations: [VSCodeInstallation],
        selectedBundleURL: URL? = nil
    ) {
        self.installations = installations
        let selectedURL = selectedBundleURL?.standardizedFileURL
        let selected = selectedURL.flatMap { requested in
            installations.first { $0.bundleURL == requested }
        }
        let supported = installations.filter(\.isSupported)

        if selectedURL != nil {
            selectedInstallation = selected?.isSupported == true ? selected : nil
            if let selected {
                status = selected.isSupported ? .supported : .unsupported
                detail =
                    selected.isSupported
                    ? nil
                    : "\(selected.edition.displayName) \(selected.version) is outside the supported 1.90-or-later 1.x range."
            } else {
                status = .missing
                detail = "The selected application bundle is not a recognized VS Code Stable or Insiders installation."
            }
        } else if supported.count == 1 {
            selectedInstallation = supported[0]
            status = .supported
            detail = nil
        } else if supported.count > 1 {
            selectedInstallation = nil
            status = .ambiguous
            detail = "Multiple supported VS Code installations were found; choose the application bundle to connect."
        } else if installations.isEmpty {
            selectedInstallation = nil
            status = .missing
            detail = "No standard VS Code Stable or Insiders installation was found."
        } else {
            selectedInstallation = nil
            status = .unsupported
            detail = "The discovered VS Code installations are outside the supported 1.90-or-later 1.x range."
        }
    }
}

public protocol VSCodeApplicationDiscovering: Sendable {
    func discover(selectedBundleURL: URL?) async throws -> VSCodeDiscoveryReport
}

public extension VSCodeApplicationDiscovering {
    func discover() async throws -> VSCodeDiscoveryReport {
        try await discover(selectedBundleURL: nil)
    }
}

/// Locates standard Microsoft Stable and Insiders bundles through Launch Services,
/// then verifies bundle identity, version, and the documented CLI inside each bundle.
public final class VSCodeApplicationDiscovery: VSCodeApplicationDiscovering, @unchecked Sendable {
    private let candidateBundleURLs: [URL]?
    private let fileManager: FileManager

    /// Passing candidates is intended for deterministic tests. Production callers
    /// use the zero-argument initializer and receive Launch Services results.
    public init(
        candidateBundleURLs: [URL]? = nil,
        fileManager: FileManager = .default
    ) {
        self.candidateBundleURLs = candidateBundleURLs
        self.fileManager = fileManager
    }

    public func discover(selectedBundleURL: URL? = nil) async throws -> VSCodeDiscoveryReport {
        var candidates = try candidateBundleURLs ?? launchServicesCandidates()
        if let selectedBundleURL {
            candidates.append(selectedBundleURL)
        }

        var seen: Set<URL> = []
        var discovered: [VSCodeInstallation] = []
        for candidate in candidates {
            try Task.checkCancellation()
            let standardized = candidate.standardizedFileURL
            guard seen.insert(standardized).inserted else { continue }
            if let installation = inspect(bundleURL: standardized) {
                discovered.append(installation)
            }
        }
        let installations = discovered.sorted {
            if $0.edition != $1.edition {
                return editionOrder($0.edition) < editionOrder($1.edition)
            }
            return $0.bundleURL.path < $1.bundleURL.path
        }

        return VSCodeDiscoveryReport(
            installations: installations,
            selectedBundleURL: selectedBundleURL
        )
    }

    private func launchServicesCandidates() throws -> [URL] {
        var candidates = VSCodeEdition.allCases.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier)
        }
        let applicationDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
        for directory in applicationDirectories {
            try Task.checkCancellation()
            guard
                let enumerator = fileManager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isApplicationKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else { continue }
            for case let candidate as URL in enumerator where candidate.pathExtension == "app" {
                try Task.checkCancellation()
                candidates.append(candidate)
            }
        }
        return candidates
    }

    private func inspect(bundleURL: URL) -> VSCodeInstallation? {
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let infoData = try? Data(contentsOf: infoURL),
            let info = try? PropertyListSerialization.propertyList(
                from: infoData,
                options: [],
                format: nil
            ) as? [String: Any],
            let bundleIdentifier = info["CFBundleIdentifier"] as? String,
            let version = info["CFBundleShortVersionString"] as? String,
            let edition = VSCodeEdition.allCases.first(where: {
                $0.bundleIdentifier == bundleIdentifier
            })
        else {
            return nil
        }

        let executableURL = bundleURL.appendingPathComponent(
            "Contents/Resources/app/bin/\(edition.cliName)"
        )
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: executableURL.path),
            let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            let executableData = try? Data(contentsOf: executableURL, options: .mappedIfSafe)
        else { return nil }
        let executableSHA256 = SHA256.hash(data: executableData)
            .map { String(format: "%02x", $0) }
            .joined()
        return VSCodeInstallation(
            bundleURL: bundleURL,
            bundleIdentifier: bundleIdentifier,
            edition: edition,
            version: version,
            executableURL: executableURL,
            executableIdentity: ManagedFileIdentity(device: device, inode: inode),
            executableSHA256: executableSHA256
        )
    }

    private func editionOrder(_ edition: VSCodeEdition) -> Int {
        switch edition {
        case .stable: 0
        case .insiders: 1
        }
    }
}
