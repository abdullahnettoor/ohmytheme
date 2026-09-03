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

    fileprivate static func registration(
        serverSessionID: String = "server-1"
    ) -> CompanionRegistration {
        CompanionRegistration(
            serverSessionID: serverSessionID,
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

@Suite("VS Code theme adapter (issue #20)")
struct VSCodeThemeAdapterTests {
    @Test("Preparation stores source provenance and the exact versioned companion request without writing")
    func preparationStoresExactRequest() async throws {
        let fixture = try VSCodeFixture(installedVersion: "0.1.0")
        let theme = Self.preparedTheme(themeName: "Catppuccin Mocha")
        let baseline = try await fixture.adapter.prepareConnection(instance: fixture.instance)

        let plan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: theme,
            connectionBaseline: baseline.capturedPreChangeState
        )
        let payload = try JSONDecoder().decode(VSCodeThemePlanPayload.self, from: plan.artifact)

        #expect(payload.theme.variantID == "test-pack/dark")
        #expect(payload.theme.sourceType == .upstream)
        #expect(payload.theme.sourceRevision == "reviewed-revision")
        #expect(payload.request.protocolVersion == CompanionProtocol.currentVersion)
        #expect(payload.request.themeName == "Catppuccin Mocha")
        #expect(payload.request.expectedSetting == "Default Dark+")
        #expect(payload.expectation.profileID == "profile-default")
        #expect(payload.serverSessionID == "server-1")
        #expect(await fixture.platform.applyCount == 0)
    }

    @Test("Preparation compiles an exact generated VS Code artifact into the plan")
    func preparationCompilesGeneratedArtifact() async throws {
        let fixture = try VSCodeFixture(installedVersion: "0.1.0")
        let base = Fixtures.pack.variants[0]
        let generated = PreparedTheme(
            variantID: base.qualifiedID,
            variant: base,
            sourceType: .generated,
            sourceRevision: Fixtures.pack.source.revision,
            attribution: Fixtures.pack.source.attribution,
            themeSchemaVersion: Fixtures.pack.schemaVersion,
            contentDigest: base.contentDigest,
            compilerVersion: "theme-compiler-1",
            upstreamArtifact: nil
        )
        let baseline = try await fixture.adapter.prepareConnection(instance: fixture.instance)

        let plan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: generated,
            connectionBaseline: baseline.capturedPreChangeState
        )
        let payload = try JSONDecoder().decode(VSCodeThemePlanPayload.self, from: plan.artifact)

        #expect(payload.theme.sourceType == .generated)
        #expect(payload.artifact.themeName == "Test Pack Dark")
        #expect(payload.artifact.uiTheme == "vs-dark")
        #expect(payload.artifact.colors["editor.background"] == "#112233")
        #expect(payload.artifact.tokenColors.count == 3)
        #expect(payload.artifact.tokenColors[0].foreground == "#112233")
        #expect(payload.request.themeName == payload.artifact.themeName)
    }

    @Test("ThemeEngine addresses the connected instance and persists its matching acknowledgement")
    func engineApplyPersistsAcknowledgement() async throws {
        let fixture = try VSCodeFixture(installedVersion: "0.1.0")
        let store = try Self.makeStore()
        let upstream = try JSONEncoder().encode(VSCodeThemeArtifact(themeName: "Catppuccin Mocha"))
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [fixture.adapter],
            upstreamArtifacts: [
                "vscode/test-pack/dark": PinnedUpstreamArtifact(
                    adapterID: "vscode",
                    variantID: "test-pack/dark",
                    revision: "reviewed-revision",
                    contentDigest: "sha256:test",
                    payload: upstream
                )
            ],
            persistence: store
        )
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)

        let preview = try await engine.prepare(
            themeVariantID: "test-pack/dark",
            workspace: Self.workspace(instance: fixture.instance)
        )
        let report = try await engine.applyDurable(
            previewID: preview.id,
            workspace: Self.workspace(instance: fixture.instance)
        )

        #expect(report.outcomes[0].configurationState == .updated)
        #expect(report.outcomes[0].runningInstanceReach == .currentInstances)
        #expect(await fixture.platform.configuredTheme == "Catppuccin Mocha")
        #expect(await fixture.platform.lastExpectation?.profileID == "profile-default")
        let record = try #require(store.journalLoadRecords(operationID: report.operationID).first)
        let receipt = try JSONDecoder().decode(
            AdapterReceipt.self,
            from: Data(try #require(record.receiptJSON).utf8)
        )
        let details = try JSONDecoder().decode(
            VSCodeThemeReceipt.self,
            from: try #require(receipt.rollbackData)
        )
        let lastRequestID = await fixture.platform.lastRequestID
        #expect(details.acknowledgement?.id == lastRequestID)
        #expect(details.acknowledgement?.requestedSetting == "Catppuccin Mocha")
        #expect(details.acknowledgement?.previousSetting == "Default Dark+")
    }

    @Test("A workspace override is reported as configured but not active in the current instance")
    func reportsWorkspaceOverrideAndLiveReach() async throws {
        let fixture = try VSCodeFixture(installedVersion: "0.1.0")
        await fixture.platform.setOverride(
            CompanionOverride(scope: .workspace, folder: nil, value: "Solarized Dark")
        )
        let baseline = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        let plan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: Self.preparedTheme(themeName: "Catppuccin Mocha"),
            connectionBaseline: baseline.capturedPreChangeState
        )

        let receipt = try await fixture.adapter.apply(plan)

        #expect(receipt.configurationState == .updated)
        #expect(receipt.runningInstanceReach == .unavailable)
        #expect(receipt.detail?.contains("workspace") == true)
    }

    @Test("A timed-out update is recovered when inspection proves the intended setting")
    func timeoutAfterMutationRecovers() async throws {
        let fixture = try VSCodeFixture(installedVersion: "0.1.0")
        await fixture.platform.failNextApply(.timeout, afterMutation: true)
        let store = try Self.makeStore()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [fixture.adapter],
            upstreamArtifacts: Self.upstreamArtifacts(themeName: "Catppuccin Mocha"),
            persistence: store
        )
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let workspace = Self.workspace(instance: fixture.instance)
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)

        let report = try await engine.applyDurable(previewID: preview.id, workspace: workspace)

        #expect(report.outcomes[0].configurationState == .updated)
        #expect(report.outcomes[0].detail?.contains("Recovered after apply error") == true)
    }

    @Test("A failed verification acknowledgement recovers a completed setting update")
    func failedAcknowledgementAfterMutationRecovers() async throws {
        let fixture = try VSCodeFixture(installedVersion: "0.1.0")
        await fixture.platform.failNextAcknowledgement(afterMutation: true)
        let store = try Self.makeStore()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [fixture.adapter],
            upstreamArtifacts: Self.upstreamArtifacts(themeName: "Catppuccin Mocha"),
            persistence: store
        )
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let workspace = Self.workspace(instance: fixture.instance)
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)

        let report = try await engine.applyDurable(previewID: preview.id, workspace: workspace)

        #expect(report.outcomes[0].configurationState == .updated)
        #expect(report.outcomes[0].detail?.contains("Recovered after apply error") == true)
    }

    @Test("An uncertain update stays pending until a later inspection can reconcile it")
    func unavailableImmediateRecoveryStaysPending() async throws {
        let fixture = try VSCodeFixture(installedVersion: "0.1.0")
        await fixture.platform.failNextApply(.timeout, afterMutation: true)
        await fixture.platform.failInspectionAfterNextApply()
        let store = try Self.makeStore()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [fixture.adapter],
            upstreamArtifacts: Self.upstreamArtifacts(themeName: "Catppuccin Mocha"),
            persistence: store
        )
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let workspace = Self.workspace(instance: fixture.instance)
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)

        let report = try await engine.applyDurable(previewID: preview.id, workspace: workspace)

        #expect(report.outcomes[0].configurationState == .failed)
        #expect(try store.journalLoadOperation(id: report.operationID)?.state == .applying)
        #expect(try store.journalLoadRecords(operationID: report.operationID)[0].phase == .applying)

        try await engine.reconcileInterruptedOperations()

        #expect(try store.journalLoadOperation(id: report.operationID)?.state == .reconciled)
        let record = try store.journalLoadRecords(operationID: report.operationID)[0]
        #expect(record.phase == .applied)
        #expect(record.receiptJSON != nil)
    }

    @Test(
        "Transport and acknowledgement failures remain specific when no intended change can be recovered",
        arguments: [
            VSCodeCompanionRequestError.timeout,
            .disconnected,
            .staleRequest,
            .duplicateRequest,
            .unsupportedProtocol,
            .malformedAcknowledgement,
        ]
    )
    func reportsSpecificRecoverableFailure(error: VSCodeCompanionRequestError) async throws {
        let fixture = try VSCodeFixture(installedVersion: "0.1.0")
        await fixture.platform.failNextApply(error, afterMutation: false)
        let baseline = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        let plan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: Self.preparedTheme(themeName: "Catppuccin Mocha"),
            connectionBaseline: baseline.capturedPreChangeState
        )

        do {
            _ = try await fixture.adapter.apply(plan)
            Issue.record("expected a specific companion request failure")
        } catch let received as VSCodeThemeRecoveryRequired {
            #expect(received.requestError == error)
            #expect(received.capabilityOutcomeDetail.isEmpty == false)
        } catch let received as VSCodeThemeAdapterError {
            #expect(received == .requestFailed(error))
            #expect(received.capabilityOutcomeDetail.isEmpty == false)
        }
    }

    @Test("Undo sends a new acknowledged update and restores the prior profile setting")
    func undoUsesNewAcknowledgedUpdate() async throws {
        let fixture = try VSCodeFixture(installedVersion: "0.1.0")
        let store = try Self.makeStore()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [fixture.adapter],
            upstreamArtifacts: Self.upstreamArtifacts(themeName: "Catppuccin Mocha"),
            persistence: store
        )
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let workspace = Self.workspace(instance: fixture.instance)
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        _ = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        let applyRequestID = await fixture.platform.lastRequestID
        await fixture.platform.replaceRegistration(
            VSCodeConnectionAdapterTests.registration(serverSessionID: "server-2")
        )

        let undo = try await engine.undoLast(workspace: workspace)

        #expect(undo.outcomes[0].configurationState == .updated)
        #expect(await fixture.platform.configuredTheme == "Default Dark+")
        #expect(await fixture.platform.applyCount == 2)
        #expect(await fixture.platform.lastRequestID != applyRequestID)
        let undoRecord = try #require(store.journalLoadRecords(operationID: undo.operationID).first)
        let undoReceipt = try JSONDecoder().decode(
            AdapterReceipt.self,
            from: Data(try #require(undoRecord.receiptJSON).utf8)
        )
        let details = try JSONDecoder().decode(
            VSCodeThemeReceipt.self,
            from: try #require(undoReceipt.rollbackData)
        )
        #expect(details.acknowledgement?.requestedSetting == "Default Dark+")
        #expect(details.acknowledgement?.previousSetting == "Catppuccin Mocha")
    }

    @Test("An unacknowledged Undo stays pending until inspection can reconcile it")
    func uncertainUndoReconciles() async throws {
        let fixture = try VSCodeFixture(installedVersion: "0.1.0")
        let store = try Self.makeStore()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [fixture.adapter],
            upstreamArtifacts: Self.upstreamArtifacts(themeName: "Catppuccin Mocha"),
            persistence: store
        )
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let workspace = Self.workspace(instance: fixture.instance)
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let apply = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        await fixture.platform.failNextApply(.timeout, afterMutation: true)
        await fixture.platform.failInspectionAfterNextApply()

        let undo = try await engine.undoLast(workspace: workspace)

        #expect(undo.outcomes[0].configurationState == .failed)
        #expect(try store.journalLoadOperation(id: undo.operationID)?.state == .applying)
        #expect(try store.journalLoadRecords(operationID: apply.operationID)[0].phase == .applied)
        await #expect(throws: (any Error).self) {
            try await engine.reconcileInterruptedOperations()
        }

        try await engine.reconcileInterruptedOperations()

        #expect(try store.journalLoadOperation(id: undo.operationID)?.state == .reconciled)
        #expect(try store.journalLoadRecords(operationID: undo.operationID)[0].phase == .applied)
        #expect(try store.journalLoadRecords(operationID: apply.operationID)[0].phase == .rolledBack)
        #expect(await fixture.platform.configuredTheme == "Default Dark+")
    }

    @Test("An interrupted acknowledged Undo is reconciled and its source receipt is retired")
    func interruptedUndoReconciles() async throws {
        let fixture = try VSCodeFixture(installedVersion: "0.1.0")
        let store = try Self.makeStore()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [fixture.adapter],
            upstreamArtifacts: Self.upstreamArtifacts(themeName: "Catppuccin Mocha"),
            persistence: store
        )
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let workspace = Self.workspace(instance: fixture.instance)
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let apply = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        let originalApplyRecord = try store.journalLoadRecords(operationID: apply.operationID)[0]
        let undo = try await engine.undoLast(workspace: workspace)
        let completedUndoRecord = try store.journalLoadRecords(operationID: undo.operationID)[0]

        // Model a crash after VS Code acknowledged Undo but before its receipt and
        // source-record retirement became durable.
        try store.journalTransitionState(operationID: undo.operationID, to: .applying)
        try store.journalSaveRecord(
            JournaledRecord(
                operationID: completedUndoRecord.operationID,
                targetInstanceID: completedUndoRecord.targetInstanceID,
                ordinal: completedUndoRecord.ordinal,
                adapterID: completedUndoRecord.adapterID,
                adapterVersion: completedUndoRecord.adapterVersion,
                capabilityID: completedUndoRecord.capabilityID,
                phase: .applying,
                intendedChangeDigest: completedUndoRecord.intendedChangeDigest,
                staleStateToken: completedUndoRecord.staleStateToken,
                planDigest: completedUndoRecord.planDigest,
                receiptJSON: originalApplyRecord.receiptJSON,
                detail: nil
            )
        )
        var sourceRecord = originalApplyRecord
        sourceRecord.phase = .applied
        try store.journalSaveRecord(sourceRecord)

        try await engine.reconcileInterruptedOperations()

        let recoveredUndo = try store.journalLoadRecords(operationID: undo.operationID)[0]
        #expect(recoveredUndo.phase == .applied)
        #expect(recoveredUndo.receiptJSON != originalApplyRecord.receiptJSON)
        #expect(try store.journalLoadRecords(operationID: apply.operationID)[0].phase == .rolledBack)
        #expect(await fixture.platform.configuredTheme == "Default Dark+")
    }

    @Test("Recovery retires the source when Undo receipt was durable before interruption")
    func durableUndoReceiptRetiresSourceDuringRecovery() async throws {
        let fixture = try VSCodeFixture(installedVersion: "0.1.0")
        let store = try Self.makeStore()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [fixture.adapter],
            upstreamArtifacts: Self.upstreamArtifacts(themeName: "Catppuccin Mocha"),
            persistence: store
        )
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let workspace = Self.workspace(instance: fixture.instance)
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let apply = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        let undo = try await engine.undoLast(workspace: workspace)
        var sourceRecord = try store.journalLoadRecords(operationID: apply.operationID)[0]
        sourceRecord.phase = .applied
        try store.journalSaveRecord(sourceRecord)
        try store.journalTransitionState(operationID: undo.operationID, to: .applying)

        try await engine.reconcileInterruptedOperations()

        #expect(try store.journalLoadRecords(operationID: apply.operationID)[0].phase == .rolledBack)
        #expect(try store.journalLoadOperation(id: undo.operationID)?.state == .reconciled)
    }

    @Test("Undo can retry after the intended companion was unavailable before mutation")
    func undoRetriesAfterPreMutationDisconnect() async throws {
        let fixture = try VSCodeFixture(installedVersion: "0.1.0")
        let store = try Self.makeStore()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [fixture.adapter],
            upstreamArtifacts: Self.upstreamArtifacts(themeName: "Catppuccin Mocha"),
            persistence: store
        )
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let workspace = Self.workspace(instance: fixture.instance)
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        let apply = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        await fixture.platform.replaceRegistration(nil)

        let unavailable = try await engine.undoLast(workspace: workspace)

        #expect(unavailable.outcomes[0].configurationState == .unavailable)
        #expect(try store.journalLoadRecords(operationID: apply.operationID)[0].phase == .applied)

        await fixture.platform.replaceRegistration(VSCodeConnectionAdapterTests.registration())
        let retried = try await engine.undoLast(workspace: workspace)
        #expect(retried.outcomes[0].configurationState == .updated)
        #expect(await fixture.platform.configuredTheme == "Default Dark+")
    }

    @Test("Undo refuses to overwrite a theme changed outside Oh My Theme")
    func undoRefusesExternalThemeChange() async throws {
        let fixture = try VSCodeFixture(installedVersion: "0.1.0")
        let store = try Self.makeStore()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [fixture.adapter],
            upstreamArtifacts: Self.upstreamArtifacts(themeName: "Catppuccin Mocha"),
            persistence: store
        )
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let workspace = Self.workspace(instance: fixture.instance)
        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        _ = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        await fixture.platform.replaceConfiguredTheme("External Theme")

        let undo = try await engine.undoLast(workspace: workspace)

        #expect(undo.outcomes[0].configurationState == .conflicted)
        #expect(await fixture.platform.configuredTheme == "External Theme")
    }

    private static func preparedTheme(themeName: String) -> PreparedTheme {
        PreparedTheme(
            variantID: Fixtures.pack.variants[0].qualifiedID,
            variant: Fixtures.pack.variants[0],
            sourceType: .upstream,
            sourceRevision: Fixtures.pack.source.revision,
            attribution: Fixtures.pack.source.attribution,
            themeSchemaVersion: Fixtures.pack.schemaVersion,
            contentDigest: Fixtures.pack.variants[0].contentDigest,
            compilerVersion: "theme-compiler-1",
            upstreamArtifact: try! JSONEncoder().encode(VSCodeThemeArtifact(themeName: themeName))
        )
    }

    private static func upstreamArtifacts(themeName: String) -> [String: PinnedUpstreamArtifact] {
        let payload = try! JSONEncoder().encode(VSCodeThemeArtifact(themeName: themeName))
        return [
            "vscode/test-pack/dark": PinnedUpstreamArtifact(
                adapterID: "vscode",
                variantID: "test-pack/dark",
                revision: "reviewed-revision",
                contentDigest: "sha256:test",
                payload: payload
            )
        ]
    }

    private static func workspace(instance: ConnectedTargetInstance) -> Workspace {
        Workspace(id: .myMac, displayName: "My Mac", connectedTargetInstances: [instance])
    }

    private static func makeStore() throws -> PersistenceStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-vscode-theme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
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
    private var nextApplyFailure: (error: VSCodeCompanionRequestError, afterMutation: Bool)?
    private var shouldFailInspectionAfterNextApply = false
    private var shouldFailNextInspection = false
    private var failedAcknowledgementAfterMutation: Bool?
    private var override: CompanionOverride?
    private(set) var installCount = 0
    private(set) var applyCount = 0
    private(set) var configuredTheme: String? = "Default Dark+"
    private(set) var lastExpectation: VSCodeRegistrationExpectation?
    private(set) var lastRequestID: UUID?

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

    func inspectTheme(
        serverSessionID: String,
        matching expectation: VSCodeRegistrationExpectation
    ) async throws -> CompanionThemeInspection {
        guard let registered,
            registered.serverSessionID == serverSessionID,
            expectation.matches(registered)
        else {
            throw VSCodeCompanionRequestError.disconnected
        }
        if shouldFailNextInspection {
            shouldFailNextInspection = false
            throw VSCodeCompanionRequestError.disconnected
        }
        lastExpectation = expectation
        return CompanionThemeInspection(
            configuredSetting: configuredTheme,
            effectiveSetting: override?.value ?? configuredTheme,
            overrides: override.map { [$0] } ?? []
        )
    }

    func applyTheme(
        _ request: VSCodeCompanionThemeRequest,
        serverSessionID: String,
        matching expectation: VSCodeRegistrationExpectation
    ) async throws -> CompanionApplyOutcome {
        guard let registered,
            registered.serverSessionID == serverSessionID,
            expectation.matches(registered)
        else {
            throw VSCodeCompanionRequestError.disconnected
        }
        lastExpectation = expectation
        applyCount += 1
        if let afterMutation = failedAcknowledgementAfterMutation {
            failedAcknowledgementAfterMutation = nil
            let previous = configuredTheme
            if afterMutation {
                configuredTheme = request.themeName
            }
            let requestID = UUID()
            lastRequestID = requestID
            return CompanionApplyOutcome(
                sessionID: registered.serverSessionID,
                acknowledgement: CompanionApplyThemeAckMessage(
                    protocolVersion: request.protocolVersion,
                    id: requestID,
                    status: .failed,
                    effectiveSetting: configuredTheme,
                    requestedSetting: request.themeName,
                    previousSetting: previous,
                    configuredSetting: configuredTheme,
                    overrides: [],
                    failure: CompanionApplyFailure(
                        code: "verification_mismatch",
                        message: "verification failed"
                    )
                )
            )
        }
        if let nextApplyFailure {
            self.nextApplyFailure = nil
            if nextApplyFailure.afterMutation {
                configuredTheme = request.themeName
            }
            if shouldFailInspectionAfterNextApply {
                shouldFailInspectionAfterNextApply = false
                shouldFailNextInspection = true
            }
            throw nextApplyFailure.error
        }
        guard configuredTheme == request.expectedSetting else {
            throw VSCodeCompanionRequestError.staleRequest
        }
        let previous = configuredTheme
        configuredTheme = request.themeName
        let requestID = UUID()
        lastRequestID = requestID
        return CompanionApplyOutcome(
            sessionID: registered.serverSessionID,
            acknowledgement: CompanionApplyThemeAckMessage(
                protocolVersion: request.protocolVersion,
                id: requestID,
                status: override == nil ? .applied : .overridden,
                effectiveSetting: override?.value ?? configuredTheme,
                requestedSetting: request.themeName,
                previousSetting: previous,
                configuredSetting: configuredTheme,
                overrides: override.map { [$0] } ?? [],
                failure: nil
            )
        )
    }

    var installedVersion: String? { installed?.version }

    func failInstalledCompanion(onCall call: Int) {
        installedCompanionFailureCall = call
    }

    func failNextInstall() {
        shouldFailNextInstall = true
    }

    func failNextApply(_ error: VSCodeCompanionRequestError, afterMutation: Bool) {
        nextApplyFailure = (error, afterMutation)
    }

    func failInspectionAfterNextApply() {
        shouldFailInspectionAfterNextApply = true
    }

    func failNextAcknowledgement(afterMutation: Bool) {
        failedAcknowledgementAfterMutation = afterMutation
    }

    func setOverride(_ value: CompanionOverride?) {
        override = value
    }

    func replaceConfiguredTheme(_ value: String?) {
        configuredTheme = value
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
