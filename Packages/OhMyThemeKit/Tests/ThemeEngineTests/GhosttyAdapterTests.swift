import Foundation
import Persistence
import PlatformClients
import Testing
import ThemeModel

@testable import ThemeEngine

@Suite("Ghostty connection adapter (issue #14)")
struct GhosttyAdapterTests {
    @Test("Discovery reports supported, unsupported, missing, and ambiguous installations")
    func discoveryStates() async throws {
        let supported = GhosttyInstallation(
            executableURL: URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            version: "1.3.1"
        )
        let unsupported = GhosttyInstallation(
            executableURL: URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            version: "1.2.3"
        )

        #expect(GhosttyDiscoveryReport(installations: []).installationStatus == .missing)
        #expect(GhosttyDiscoveryReport(installations: [supported]).installationStatus == .supported)
        #expect(GhosttyDiscoveryReport(installations: [unsupported]).installationStatus == .unsupported)
        #expect(
            GhosttyDiscoveryReport(installations: [supported, supported]).installationStatus == .ambiguous
        )
    }

    @Test("Connection plan exposes the resolved config, include, artifact, and side effects")
    func planDetails() async throws {
        let fixture = try Fixture()
        let adapter = fixture.adapter()
        let plan = try await adapter.prepareConnection(instance: fixture.instance)
        let details = try #require(plan.ghosttyDetails)

        #expect(details.resolvedConfigURL == fixture.parentURL)
        #expect(details.resolvedConfigPermissions == 0o644)
        #expect(details.linkedSourceURL == nil)
        #expect(details.includeLine == "config-file = ?oh-my-theme/config.ghostty")
        #expect(details.managedArtifactURL == fixture.managedURL)
        #expect(details.managedArtifactPermissions == 0o600)
        #expect(plan.expectedSideEffects.contains("Ghostty: managed include and fragment"))
        #expect(plan.userActions.contains(UserAction(title: "Reload Ghostty", detail: "Press cmd+shift+,")))
    }

    @Test("Connect validates the staged graph and writes only the managed include and fragment")
    func connectWritesOwnedFiles() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let adapter = fixture.adapter()
        let plan = try await adapter.prepareConnection(instance: fixture.instance)
        let before = try Data(contentsOf: fixture.parentURL)

        let receipt = try await adapter.connect(plan)
        let parent = try String(contentsOf: fixture.parentURL, encoding: .utf8)
        let fragment = try String(contentsOf: fixture.managedURL, encoding: .utf8)

        #expect(receipt.configurationState == .updated)
        #expect(receipt.runningInstanceReach == .reloadRequired)
        #expect(try Data(contentsOf: fixture.parentURL) != before)
        #expect(parent.contains("config-file = ?oh-my-theme/config.ghostty"))
        #expect(fragment == "# Managed by Oh My Theme\n")
        #expect(await fixture.runtime.validations == 1)
    }

    @Test("An ordinary linked source requires explicit approval")
    func linkedSourceRequiresApproval() async throws {
        let fixture = try Fixture(linkedParent: true)
        let adapter = fixture.adapter()
        let plan = try await adapter.prepareConnection(instance: fixture.instance)
        let details = try #require(plan.ghosttyDetails)
        #expect(details.linkedSourceURL == fixture.parentSourceURL)
        #expect(plan.requiresApproval)

        await #expect(throws: GhosttyAdapterError.self) {
            _ = try await adapter.connect(plan)
        }
        let approved = try await adapter.prepareConnection(
            instance: fixture.instance,
            approveLinkedSource: true
        )
        _ = try await adapter.connect(approved)
        #expect(try String(contentsOf: fixture.parentSourceURL, encoding: .utf8).contains("config-file"))
    }

    @Test("A Nix-managed source remains unavailable")
    func nixSourceIsUnavailable() async throws {
        let fixture = try Fixture(nixManagedParent: true)
        let adapter = fixture.adapter()

        await #expect(throws: GhosttyAdapterError.self) {
            _ = try await adapter.prepareConnection(instance: fixture.instance)
        }
    }

    @Test("Connect refuses an external edit at the write boundary")
    func staleConnectionConflicts() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let adapter = fixture.adapter()
        let plan = try await adapter.prepareConnection(instance: fixture.instance)
        try Data("background = #202020\n".utf8).write(to: fixture.parentURL)

        await #expect(throws: GhosttyAdapterError.self) {
            _ = try await adapter.connect(plan)
        }
        #expect(try String(contentsOf: fixture.parentURL, encoding: .utf8) == "background = #202020\n")
    }

    @Test("Disconnect restores the connection baseline and refuses external edits")
    func disconnectRestoresBaseline() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let adapter = fixture.adapter()
        let plan = try await adapter.prepareConnection(instance: fixture.instance)
        _ = try await adapter.connect(plan)
        let disconnectPlan = try await adapter.prepareDisconnect(
            instance: fixture.instance,
            baseline: fixture.baseline(for: plan),
            baselineData: plan.capturedPreChangeState
        )

        let receipt = try await adapter.disconnect(
            disconnectPlan,
            baseline: plan.capturedPreChangeState
        )

        #expect(receipt.configurationState == .updated)
        #expect(try String(contentsOf: fixture.parentURL, encoding: .utf8) == "background = #101010\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.managedURL.path))
    }

    @Test("Disconnect refuses an external edit before restoring the baseline")
    func disconnectConflict() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let adapter = fixture.adapter()
        let plan = try await adapter.prepareConnection(instance: fixture.instance)
        _ = try await adapter.connect(plan)
        let baseline = try fixture.baseline(for: plan)
        try Data("background = #303030\nconfig-file = ?oh-my-theme/config.ghostty\n".utf8)
            .write(to: fixture.parentURL)

        await #expect(throws: GhosttyAdapterError.self) {
            _ = try await adapter.prepareDisconnect(
                instance: fixture.instance,
                baseline: baseline,
                baselineData: plan.capturedPreChangeState
            )
        }
        #expect(FileManager.default.fileExists(atPath: fixture.managedURL.path))
    }

    @Test("Durable connect persists the plan and reconciles an interrupted connection")
    func durableConnectReconciles() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let adapter = fixture.adapter()
        let databaseURL = fixture.directory.appendingPathComponent("state.sqlite")
        let store = try PersistenceStore(
            databaseURL: databaseURL,
            contentStoreURL: fixture.directory.appendingPathComponent("recovery", isDirectory: true)
        )
        let engine = ThemeEngine(packs: [], adapters: [adapter], persistence: store)
        let report = try await engine.connect(instance: fixture.instance, workspace: .myMac)

        #expect(report.outcomes[0].configurationState == .updated)
        #expect(try store.journalLoadConnectionBaseline(targetInstanceID: fixture.instance.id) != nil)
        let records = try store.journalLoadRecords(operationID: report.operationID)
        #expect(records[0].phase == .applied)

        try store.journalTransitionState(operationID: report.operationID, to: .applying)
        var interrupted = records[0]
        interrupted.phase = .applying
        try store.journalSaveRecord(interrupted)

        let relaunched = ThemeEngine(packs: [], adapters: [fixture.adapter()], persistence: store)
        try await relaunched.reconcileInterruptedOperations()
        let reconciled = try store.journalLoadRecords(operationID: report.operationID)
        #expect(reconciled[0].phase == .reconciledIntended)
    }

    @Test("Engine restore delegates to the Ghostty connection baseline")
    func engineRestore() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let adapter = fixture.adapter()
        let store = try PersistenceStore(
            databaseURL: fixture.directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: fixture.directory.appendingPathComponent("recovery", isDirectory: true)
        )
        let engine = ThemeEngine(packs: [], adapters: [adapter], persistence: store)
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let report = try await engine.restore(instance: fixture.instance, workspace: .myMac)

        #expect(report.outcomes[0].configurationState == .updated)
        #expect(try String(contentsOf: fixture.parentURL, encoding: .utf8) == "background = #101010\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.managedURL.path))
    }

    @Test("Restore reports a conflict instead of overwriting an external edit")
    func restoreConflict() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let adapter = fixture.adapter()
        let store = try PersistenceStore(
            databaseURL: fixture.directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: fixture.directory.appendingPathComponent("recovery", isDirectory: true)
        )
        let engine = ThemeEngine(packs: [], adapters: [adapter], persistence: store)
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let external = "background = #303030\nconfig-file = ?oh-my-theme/config.ghostty\n"
        try Data(external.utf8).write(to: fixture.parentURL)

        let report = try await engine.restore(instance: fixture.instance, workspace: .myMac)

        #expect(report.outcomes[0].configurationState == .conflicted)
        #expect(try String(contentsOf: fixture.parentURL, encoding: .utf8) == external)
    }

    private struct Fixture {
        let directory: URL
        let parentURL: URL
        let parentSourceURL: URL
        let managedURL: URL
        let instance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "ghostty.default"),
            displayName: "Ghostty, Default Configuration",
            adapterID: "ghostty"
        )
        let runtime: TestGhosttyRuntime

        init(
            parentContents: String = "",
            linkedParent: Bool = false,
            nixManagedParent: Bool = false
        ) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("oh-my-theme-ghostty-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let configDirectory = directory.appendingPathComponent("config", isDirectory: true)
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            parentSourceURL = configDirectory.appendingPathComponent("config.ghostty")
            parentURL =
                linkedParent
                ? directory.appendingPathComponent("config.ghostty")
                : parentSourceURL
            managedURL =
                configDirectory
                .appendingPathComponent("oh-my-theme", isDirectory: true)
                .appendingPathComponent("config.ghostty")
            try Data(parentContents.utf8).write(to: parentSourceURL)
            if linkedParent {
                try FileManager.default.createSymbolicLink(
                    at: parentURL,
                    withDestinationURL: parentSourceURL
                )
            }
            if nixManagedParent {
                let nixRoot = directory.appendingPathComponent("nix", isDirectory: true)
                let nixSource = nixRoot.appendingPathComponent("store/config.ghostty")
                try FileManager.default.createDirectory(
                    at: nixSource.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(parentContents.utf8).write(to: nixSource)
                if FileManager.default.fileExists(atPath: parentURL.path) {
                    try FileManager.default.removeItem(at: parentURL)
                }
                try FileManager.default.createSymbolicLink(at: parentURL, withDestinationURL: nixSource)
            }
            runtime = TestGhosttyRuntime()
        }

        func adapter() -> GhosttyConfigurationAdapter {
            GhosttyConfigurationAdapter(
                runtime: runtime,
                managedFiles: ManagedFiles(
                    nixRoots: [directory.appendingPathComponent("nix/store")]
                ),
                configurationURL: parentURL,
                managedArtifactURL: managedURL
            )
        }

        func baseline(for plan: ConnectionPlan) throws -> StoredConnectionBaseline {
            StoredConnectionBaseline(
                targetInstanceID: instance.id,
                adapterID: "ghostty",
                adapterVersion: "1",
                baselineReference: ContentReference(digest: "baseline", byteCount: plan.capturedPreChangeState.count),
                capturedAt: Date()
            )
        }
    }
}

actor TestGhosttyRuntime: GhosttyRuntime {
    private(set) var validations = 0

    func discoverInstallations() async throws -> [GhosttyInstallation] {
        [
            GhosttyInstallation(
                executableURL: URL(fileURLWithPath: "/usr/local/bin/ghostty"),
                version: "1.3.1"
            )
        ]
    }

    func validate(_ input: GhosttyValidationInput) async throws {
        validations += 1
    }
}
