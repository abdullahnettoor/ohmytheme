import Foundation
import Testing

@testable import PlatformClients

@Suite("VS Code application discovery (issue #19)")
struct VSCodeApplicationDiscoveryTests {
    @Test("Discovery identifies supported editions and requires a choice when installations are ambiguous")
    func discoversSupportedEditionsAndAmbiguity() async throws {
        let fixture = try ApplicationFixture()
        let stable = try fixture.makeApplication(
            name: "Visual Studio Code",
            bundleIdentifier: "com.microsoft.VSCode",
            version: "1.95.2",
            cliName: "code"
        )
        let insiders = try fixture.makeApplication(
            name: "Visual Studio Code - Insiders",
            bundleIdentifier: "com.microsoft.VSCodeInsiders",
            version: "1.96.0",
            cliName: "code"
        )
        let discovery = VSCodeApplicationDiscovery(candidateBundleURLs: [stable, insiders])

        let ambiguous = try await discovery.discover()
        let selected = try await discovery.discover(selectedBundleURL: stable)

        #expect(ambiguous.status == .ambiguous)
        #expect(ambiguous.installations.map(\.edition) == [.stable, .insiders])
        #expect(ambiguous.installations.map(\.isSupported) == [true, true])
        #expect(selected.status == .supported)
        #expect(selected.selectedInstallation?.bundleURL == stable.standardizedFileURL)
        #expect(
            selected.selectedInstallation?.executableURL
                == stable.appendingPathComponent("Contents/Resources/app/bin/code")
        )
    }

    @Test("Discovery rejects versions outside the pinned extension engine range")
    func rejectsUnsupportedVersion() async throws {
        let fixture = try ApplicationFixture()
        let old = try fixture.makeApplication(
            name: "Visual Studio Code 1.89",
            bundleIdentifier: "com.microsoft.VSCode",
            version: "1.89.9",
            cliName: "code"
        )
        let discovery = VSCodeApplicationDiscovery(candidateBundleURLs: [old])

        let report = try await discovery.discover(selectedBundleURL: old)

        #expect(report.status == .unsupported)
        #expect(report.selectedInstallation == nil)
        #expect(report.installations.first?.isSupported == false)
    }
}

private struct ApplicationFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-vscode-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makeApplication(
        name: String,
        bundleIdentifier: String,
        version: String,
        cliName: String
    ) throws -> URL {
        let bundle = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let cli = contents.appendingPathComponent("Resources/app/bin/\(cliName)")
        try FileManager.default.createDirectory(
            at: cli.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": version,
            "CFBundlePackageType": "APPL",
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: cli.path
        )
        return bundle
    }
}
