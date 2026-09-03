import Adapters
import CryptoKit
import Foundation
import Persistence
import PlatformClients
import Testing
import ThemeModel

@testable import ThemeEngine

@Suite("VS Code connection adapter (issue #19)")
struct VSCodeConnectionAdapterTests {
    @Test("Connection preview is read-only and explains the pinned companion, executable, socket, scope, and identity")
    func previewExplainsApprovedSetup() async throws {
        let fixture = try VSCodeFixture(installedVersion: nil)

        let plan = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        let details = try JSONDecoder().decode(VSCodeConnectionPayload.self, from: #require(plan.opaquePayload))
        let baseline = try JSONDecoder().decode(
            VSCodeConnectionBaseline.self,
            from: plan.capturedPreChangeState
        )

        #expect(plan.requiresApproval)
        #expect(details.artifact == fixture.artifact)
        #expect(details.installation.executableURL == fixture.installation.executableURL)
        #expect(details.socketBehavior.contains("Unix-domain socket"))
        #expect(details.requestedScope == .global)
        #expect(details.expectation.profileName == "Default")
        #expect(details.expectation.windowID == "window-1")
        #expect(baseline.installedCompanion == nil)
        #expect(await fixture.platform.installCount == 0)
    }

    @Test("Approved connection installs once and accepts only the intended registration")
    func connectsExpectedRegistration() async throws {
        let fixture = try VSCodeFixture(installedVersion: nil)
        let unapproved = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        await #expect(throws: VSCodeConnectionAdapterError.approvalRequired) {
            _ = try await fixture.adapter.connect(unapproved)
        }

        let approved = try await fixture.adapter.prepareConnection(
            instance: fixture.instance,
            approveLinkedSource: true
        )
        let receipt = try await fixture.adapter.connect(approved)

        #expect(receipt.configurationState == .updated)
        #expect(receipt.runningInstanceReach == .currentInstances)
        #expect(await fixture.platform.installCount == 1)
        #expect(receipt.detail?.contains("Default") == true)
    }

    @Test("Connection rejects a registration from another process or window")
    func rejectsWrongRegistrationIdentity() async throws {
        let fixture = try VSCodeFixture(installedVersion: "0.1.0")
        await fixture.platform.replaceRegistration(
            CompanionRegistration(
                serverSessionID: "other-server",
                extensionVersion: "0.1.0",
                vscode: CompanionVSCodeIdentity(
                    edition: "vscode",
                    version: "1.95.2",
                    profileName: "Default",
                    profileId: "profile-default",
                    machineId: "machine-1",
                    sessionId: "other-window",
                    processId: 99,
                    windowId: "other-window"
                ),
                capabilities: ["colorTheme"],
                currentSettings: [:]
            )
        )
        let plan = try await fixture.adapter.prepareConnection(instance: fixture.instance)

        await #expect(throws: VSCodeConnectionAdapterError.registrationUnavailable) {
            _ = try await fixture.adapter.connect(plan)
        }
    }

    @Test("An unapproved preview does not replace the baseline used by a later approved connection")
    func unapprovedPreviewDoesNotPersistConnectionBaseline() async throws {
        let fixture = try VSCodeFixture(installedVersion: nil)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-vscode-approval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
        )
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [],
            connectionAdapters: [fixture.adapter],
            persistence: store
        )

        let preview = try await engine.connect(instance: fixture.instance, workspace: .myMac)

        #expect(preview.outcomes[0].configurationState == .permissionRequired)
        #expect(
            try store.journalLoadConnectionBaseline(targetInstanceID: fixture.instance.id) == nil
        )

        _ = try await engine.connect(
            instance: fixture.instance,
            workspace: .myMac,
            approveLinkedSource: true
        )
        let disconnected = try await engine.disconnect(
            instance: fixture.instance,
            workspace: .myMac
        )

        #expect(disconnected.outcomes[0].configurationState == .updated)
        #expect(await fixture.platform.installedVersion == nil)
    }

    @Test("Reconnect preserves the original absent baseline so Disconnect removes the owned companion")
    func reconnectPreservesOriginalBaseline() async throws {
        let fixture = try VSCodeFixture(installedVersion: nil)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-vscode-reconnect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
        )
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [],
            connectionAdapters: [fixture.adapter],
            persistence: store
        )

        _ = try await engine.connect(
            instance: fixture.instance,
            workspace: .myMac,
            approveLinkedSource: true
        )
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let report = try await engine.disconnect(instance: fixture.instance, workspace: .myMac)

        #expect(report.outcomes[0].configurationState == .updated)
        #expect(await fixture.platform.installedVersion == nil)
    }

    @Test(
        "A failed setup can reconcile and retry without retaining its abandoned ownership token",
        arguments: TestConnectionFailurePoint.allCases
    )
    func failedSetupRetryUsesFreshBaseline(failurePoint: TestConnectionFailurePoint) async throws {
        let fixture = try VSCodeFixture(installedVersion: nil)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-vscode-install-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
        )
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [],
            connectionAdapters: [fixture.adapter],
            persistence: store
        )
        switch failurePoint {
        case .installedCompanionQuery:
            await fixture.platform.failInstalledCompanion(onCall: 2)
        case .installation:
            await fixture.platform.failNextInstall()
        }

        let failed = try await engine.connect(
            instance: fixture.instance,
            workspace: .myMac,
            approveLinkedSource: true
        )
        #expect(failed.outcomes[0].configurationState != .updated)

        let connected = try await engine.connect(
            instance: fixture.instance,
            workspace: .myMac,
            approveLinkedSource: true
        )
        let disconnected = try await engine.disconnect(
            instance: fixture.instance,
            workspace: .myMac
        )

        #expect(connected.outcomes[0].configurationState == .updated)
        #expect(disconnected.outcomes[0].configurationState == .updated)
        #expect(await fixture.platform.installedVersion == nil)
    }

    @Test("A post-install registration timeout remains pending until reconciliation")
    func registrationTimeoutRequiresReconciliation() async throws {
        let fixture = try VSCodeFixture(installedVersion: nil, hasRegistration: false)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-vscode-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
        )
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [],
            connectionAdapters: [fixture.adapter],
            persistence: store
        )

        let report = try await engine.connect(
            instance: fixture.instance,
            workspace: .myMac,
            approveLinkedSource: true
        )
        #expect(report.outcomes[0].configurationState == .failed)
        #expect(try store.journalLoadOperation(id: report.operationID)?.state == .applying)

        await fixture.platform.replaceRegistration(Self.registration())
        try await engine.reconcileInterruptedOperations()

        #expect(try store.journalLoadOperation(id: report.operationID)?.state == .reconciled)
        let recoveredRecord = try store.journalLoadRecords(operationID: report.operationID)[0]
        #expect(recoveredRecord.phase == .reconciledIntended)
        #expect(recoveredRecord.receiptJSON != nil)
    }

    @Test("ThemeEngine durably stores the VS Code baseline, pending plan, and connection receipt")
    func durableEngineConnection() async throws {
        let fixture = try VSCodeFixture(installedVersion: nil)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-vscode-durable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
        )
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [],
            connectionAdapters: [fixture.adapter],
            persistence: store
        )

        let report = try await engine.connect(
            instance: fixture.instance,
            workspace: .myMac,
            approveLinkedSource: true
        )
        let baseline = try store.journalLoadConnectionBaseline(
            targetInstanceID: fixture.instance.id
        )
        let records = try store.journalLoadRecords(operationID: report.operationID)

        #expect(baseline?.adapterID == "vscode")
        #expect(records.first?.planDigest != nil)
        #expect(records.first?.receiptJSON != nil)
        #expect(records.first?.phase == .applied)
    }

    @Test("Interrupted registration recovers a receipt when the companion was already installed")
    func recoversRegistrationWithPreexistingCompanion() async throws {
        let fixture = try VSCodeFixture(installedVersion: "0.1.0")
        let plan = try await fixture.adapter.prepareConnection(instance: fixture.instance)

        #expect(try await fixture.adapter.classifyConnection(plan: plan) == .intendedAfterChange)
        let receipt = try await fixture.adapter.recoverConnectionReceipt(plan: plan)

        #expect(receipt.configurationState == .unchanged)
        #expect(receipt.runningInstanceReach == .currentInstances)
        #expect(await fixture.platform.installCount == 0)
    }

    @Test(
        "Interrupted installation is reconciled as intended and Restore and Disconnect remove only an extension installed by Oh My Theme"
    )
    func recoveryRestoreAndDisconnect() async throws {
        let fixture = try VSCodeFixture(installedVersion: nil)
        let plan = try await fixture.adapter.prepareConnection(
            instance: fixture.instance,
            approveLinkedSource: true
        )
        let connectionBaseline = try JSONDecoder().decode(
            VSCodeConnectionBaseline.self,
            from: plan.capturedPreChangeState
        )
        await fixture.platform.replaceInstalledVersion(
            "0.1.0",
            ownershipToken: connectionBaseline.installationOwnershipToken
        )

        #expect(try await fixture.adapter.classifyConnection(plan: plan) == .intendedAfterChange)
        let recovered = try await fixture.adapter.recoverConnectionReceipt(plan: plan)
        #expect(recovered.configurationState == .updated)
        let restored = try await fixture.adapter.restoreConnection(
            instance: fixture.instance,
            baseline: plan.capturedPreChangeState
        )
        #expect(restored.configurationState == .updated)
        #expect(await fixture.platform.installedVersion == nil)

        await fixture.platform.replaceInstalledVersion(
            "0.1.0",
            ownershipToken: connectionBaseline.installationOwnershipToken
        )
        let baseline = StoredConnectionBaseline(
            targetInstanceID: fixture.instance.id,
            adapterID: "vscode",
            adapterVersion: "1.0.0",
            baselineReference: ContentReference(digest: "baseline", byteCount: 1),
            capturedAt: Date()
        )
        let disconnect = try await fixture.adapter.prepareDisconnect(
            instance: fixture.instance,
            baseline: baseline,
            baselineData: plan.capturedPreChangeState
        )
        let receipt = try await fixture.adapter.disconnect(
            disconnect,
            baseline: plan.capturedPreChangeState
        )

        #expect(receipt.configurationState == .updated)
        #expect(await fixture.platform.installedVersion == nil)
    }

    @Test("Restore refuses an externally replaced companion with the same version")
    func restoreRejectsSameVersionReplacement() async throws {
        let fixture = try VSCodeFixture(installedVersion: nil)
        let plan = try await fixture.adapter.prepareConnection(
            instance: fixture.instance,
            approveLinkedSource: true
        )
        let baseline = try JSONDecoder().decode(
            VSCodeConnectionBaseline.self,
            from: plan.capturedPreChangeState
        )
        await fixture.platform.replaceInstalledVersion("0.1.0", ownershipToken: nil)

        await #expect(throws: VSCodeConnectionAdapterError.restorationConflict) {
            _ = try await fixture.adapter.restoreConnection(
                instance: fixture.instance,
                baseline: plan.capturedPreChangeState
            )
        }
        #expect(await fixture.platform.installedVersion == "0.1.0")
        #expect(baseline.installationOwnershipToken.isEmpty == false)
    }

    fileprivate static func registration() -> CompanionRegistration {
        CompanionRegistration(
            serverSessionID: "server-1",
            extensionVersion: "0.1.0",
            vscode: CompanionVSCodeIdentity(
                edition: "vscode",
                version: "1.95.2",
                profileName: "Default",
                profileId: "profile-default",
                machineId: "machine-1",
                sessionId: "window-1",
                processId: 42,
                windowId: "window-1"
            ),
            capabilities: ["colorTheme"],
            currentSettings: ["workbench.colorTheme": "Default Dark+"]
        )
    }
}

private struct VSCodeFixture {
    let platform: RecordingVSCodeConnectionPlatform
    let adapter: VSCodeConnectionAdapter
    let installation: VSCodeInstallation
    let artifact: VSCodeCompanionArtifact
    let instance: ConnectedTargetInstance

    init(installedVersion: String?, hasRegistration: Bool = true) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-vscode-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = root.appendingPathComponent("Visual Studio Code.app", isDirectory: true)
        let executable = bundle.appendingPathComponent("Contents/Resources/app/bin/code")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let executableBytes = Data("#!/bin/sh\n".utf8)
        try executableBytes.write(to: executable)
        let executableAttributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        let executableIdentity = ManagedFileIdentity(
            device: try #require((executableAttributes[.systemNumber] as? NSNumber)?.uint64Value),
            inode: try #require((executableAttributes[.systemFileNumber] as? NSNumber)?.uint64Value)
        )
        let executableDigest = SHA256.hash(data: executableBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let vsix = root.appendingPathComponent("oh-my-theme-companion-0.1.0.vsix")
        let bytes = Data("pinned companion".utf8)
        try bytes.write(to: vsix)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        installation = VSCodeInstallation(
            bundleURL: bundle,
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
        let expectation = VSCodeRegistrationExpectation(
            edition: .stable,
            applicationVersion: "1.95.2",
            extensionVersion: "0.1.0",
            profileName: "Default",
            profileID: "profile-default",
            processID: 42,
            windowID: "window-1"
        )
        instance = ConnectedTargetInstance(
            id: VSCodeConnectionAdapter.targetInstanceID(for: expectation),
            displayName: "VS Code Stable — Default",
            adapterID: "vscode"
        )
        platform = RecordingVSCodeConnectionPlatform(
            installation: installation,
            installedVersion: installedVersion,
            registration: hasRegistration ? VSCodeConnectionAdapterTests.registration() : nil
        )
        adapter = VSCodeConnectionAdapter(
            platform: platform,
            artifact: artifact,
            selectedBundleURL: bundle,
            selectedProfileName: "Default",
            expectedRegistration: expectation
        )
    }
}

private actor RecordingVSCodeConnectionPlatform: VSCodeConnectionPlatform {
    let installation: VSCodeInstallation
    private var installed: VSCodeCompanionInstallation?
    private var registered: CompanionRegistration?
    private var installedCompanionQueryCount = 0
    private var installedCompanionFailureCall: Int?
    private var shouldFailNextInstall = false
    private(set) var installCount = 0

    init(
        installation: VSCodeInstallation,
        installedVersion: String?,
        registration: CompanionRegistration?
    ) {
        self.installation = installation
        self.installed = installedVersion.map {
            VSCodeCompanionInstallation(
                extensionID: "ohmytheme.oh-my-theme-companion",
                version: $0
            )
        }
        self.registered = registration
    }

    func discover(selectedBundleURL: URL?) async throws -> VSCodeDiscoveryReport {
        VSCodeDiscoveryReport(
            installations: [installation],
            selectedBundleURL: selectedBundleURL
        )
    }

    func installedCompanion(
        using application: VSCodeInstallation,
        profileName: String,
        extensionID: String
    ) async throws -> VSCodeCompanionInstallation? {
        installedCompanionQueryCount += 1
        if installedCompanionQueryCount == installedCompanionFailureCall {
            throw TestInstallError.failed
        }
        return installed
    }

    func install(
        _ artifact: VSCodeCompanionArtifact,
        ownershipToken: String,
        using application: VSCodeInstallation,
        profileName: String
    ) async throws {
        installCount += 1
        if shouldFailNextInstall {
            shouldFailNextInstall = false
            throw TestInstallError.failed
        }
        installed = VSCodeCompanionInstallation(
            extensionID: artifact.extensionID,
            version: artifact.version,
            ownershipToken: ownershipToken
        )
    }

    func uninstall(
        extensionID: String,
        version: String,
        ownershipToken: String,
        using application: VSCodeInstallation,
        profileName: String
    ) async throws {
        guard installed?.ownershipToken == ownershipToken else {
            throw VSCodeCompanionInstallerError.ownershipMismatch
        }
        installed = nil
    }

    func registration(
        matching expectation: VSCodeRegistrationExpectation
    ) async -> CompanionRegistration? {
        guard let registered, expectation.matches(registered) else { return nil }
        return registered
    }

    var installedVersion: String? { installed?.version }

    func failInstalledCompanion(onCall call: Int) {
        installedCompanionFailureCall = call
    }

    func failNextInstall() {
        shouldFailNextInstall = true
    }

    func replaceInstalledVersion(_ version: String?, ownershipToken: String? = nil) {
        installed = version.map {
            VSCodeCompanionInstallation(
                extensionID: "ohmytheme.oh-my-theme-companion",
                version: $0,
                ownershipToken: ownershipToken
            )
        }
    }

    func replaceRegistration(_ registration: CompanionRegistration?) {
        registered = registration
    }
}

enum TestConnectionFailurePoint: CaseIterable {
    case installedCompanionQuery
    case installation
}

private enum TestInstallError: Error {
    case failed
}
