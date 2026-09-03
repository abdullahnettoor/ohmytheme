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

    @Test("System discovery deduplicates symlinked executable candidates")
    func systemDiscoveryDeduplicatesSymlinks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-discovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("ghostty")
        try Data("#!/bin/sh\nprintf '1.3.1\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        let symlink = directory.appendingPathComponent("ghostty-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: executable)
        let runtime = SystemGhosttyRuntime(
            installationCandidates: [executable.path, symlink.path]
        )

        let installations = try await runtime.discoverInstallations()

        #expect(installations.count == 1)
        #expect(installations.first?.executableURL == executable.resolvingSymlinksInPath())
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

    @Test("Theme preparation creates a deterministic Ghostty fragment without writing")
    func themePreparationIsReadOnly() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let adapter = fixture.adapter()
        let connection = try await adapter.prepareConnection(instance: fixture.instance)
        _ = try await adapter.connect(connection)
        let before = try Data(contentsOf: fixture.managedURL)
        let theme = PreparedTheme(
            variantID: Fixtures.pack.variants[0].qualifiedID,
            variant: Fixtures.pack.variants[0],
            sourceType: .generated,
            sourceRevision: Fixtures.pack.source.revision,
            attribution: Fixtures.pack.source.attribution,
            themeSchemaVersion: Fixtures.pack.schemaVersion,
            contentDigest: Fixtures.pack.variants[0].contentDigest,
            compilerVersion: "theme-compiler-1",
            upstreamArtifact: nil
        )

        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: theme)

        #expect(plan.sourceType == .generated)
        #expect(plan.activationReach == .reloadRequired)
        #expect(String(decoding: plan.artifact, as: UTF8.self).contains("background = #112233"))
        #expect(String(decoding: plan.artifact, as: UTF8.self).contains("foreground = #112233"))
        #expect(try Data(contentsOf: fixture.managedURL) == before)
    }

    @Test("Theme apply validates the staged graph and can safely undo its managed fragment")
    func themeApplyAndRollback() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let adapter = fixture.adapter()
        let connection = try await adapter.prepareConnection(instance: fixture.instance)
        _ = try await adapter.connect(connection)
        let theme = PreparedTheme(
            variantID: Fixtures.pack.variants[0].qualifiedID,
            variant: Fixtures.pack.variants[0],
            sourceType: .generated,
            sourceRevision: Fixtures.pack.source.revision,
            attribution: Fixtures.pack.source.attribution,
            themeSchemaVersion: Fixtures.pack.schemaVersion,
            contentDigest: Fixtures.pack.variants[0].contentDigest,
            compilerVersion: "theme-compiler-1",
            upstreamArtifact: nil
        )
        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: theme)

        let receipt = try await adapter.apply(plan)
        #expect(receipt.configurationState == .updated)
        #expect(receipt.runningInstanceReach == .reloadRequired)
        let applied = try String(contentsOf: fixture.managedURL, encoding: .utf8)
        #expect(applied.contains("foreground = #112233"))
        #expect(await fixture.runtime.validations == 3)

        try await adapter.rollbackApply(plan: plan, receipt: receipt)
        #expect(try String(contentsOf: fixture.managedURL, encoding: .utf8) == "# Managed by Oh My Theme\n")
    }

    @Test("Switching Theme Variants only replaces the managed Ghostty fragment")
    func switchingVariantsPreservesParentConfiguration() async throws {
        let fixture = try Fixture(parentContents: "font-family = Iosevka\n")
        let adapter = fixture.adapter()
        let connection = try await adapter.prepareConnection(instance: fixture.instance)
        _ = try await adapter.connect(connection)
        let parentAfterConnection = try Data(contentsOf: fixture.parentURL)
        let firstPlan = try await adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.theme()
        )
        _ = try await adapter.apply(firstPlan)
        let firstManagedBytes = try Data(contentsOf: fixture.managedURL)

        let baseVariant = Fixtures.pack.variants[0]
        let secondVariant = ThemeVariant(
            id: "alternate",
            displayName: "Alternate",
            appearance: baseVariant.appearance,
            contentDigest: "alternate-theme",
            roles: baseVariant.roles.merging([
                .ansiRed: ThemeColor(rawValue: "#abcdef")
            ]) { _, new in new },
            wallpaper: baseVariant.wallpaper
        )
        let secondTheme = PreparedTheme(
            variantID: "test-pack/alternate",
            variant: secondVariant,
            sourceType: .generated,
            sourceRevision: Fixtures.pack.source.revision,
            attribution: Fixtures.pack.source.attribution,
            themeSchemaVersion: Fixtures.pack.schemaVersion,
            contentDigest: secondVariant.contentDigest,
            compilerVersion: "theme-compiler-1",
            upstreamArtifact: nil
        )
        let secondPlan = try await adapter.prepareApply(
            instance: fixture.instance,
            theme: secondTheme
        )
        _ = try await adapter.apply(secondPlan)

        #expect(try Data(contentsOf: fixture.parentURL) == parentAfterConnection)
        #expect(try Data(contentsOf: fixture.managedURL) != firstManagedBytes)
        #expect(
            try String(contentsOf: fixture.parentURL, encoding: .utf8)
                .contains("font-family = Iosevka")
        )
    }

    @Test("Undo refuses an external replacement with the same theme bytes")
    func themeUndoRejectsSameContentReplacement() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let adapter = fixture.adapter()
        let connection = try await adapter.prepareConnection(instance: fixture.instance)
        _ = try await adapter.connect(connection)
        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())
        let receipt = try await adapter.apply(plan)
        let replacement = fixture.directory.appendingPathComponent("replacement.ghostty")
        try plan.artifact.write(to: replacement)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: replacement.path
        )
        _ = try FileManager.default.replaceItemAt(fixture.managedURL, withItemAt: replacement)

        await #expect(throws: GhosttyAdapterError.self) {
            try await adapter.rollbackApply(plan: plan, receipt: receipt)
        }
        #expect(try Data(contentsOf: fixture.managedURL) == plan.artifact)
    }

    @Test("Theme apply preserves an external edit instead of overwriting it")
    func themeApplyConflict() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let adapter = fixture.adapter()
        let connection = try await adapter.prepareConnection(instance: fixture.instance)
        _ = try await adapter.connect(connection)
        let theme = PreparedTheme(
            variantID: Fixtures.pack.variants[0].qualifiedID,
            variant: Fixtures.pack.variants[0],
            sourceType: .generated,
            sourceRevision: Fixtures.pack.source.revision,
            attribution: Fixtures.pack.source.attribution,
            themeSchemaVersion: Fixtures.pack.schemaVersion,
            contentDigest: Fixtures.pack.variants[0].contentDigest,
            compilerVersion: "theme-compiler-1",
            upstreamArtifact: nil
        )
        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: theme)
        let external = Data("# changed outside Oh My Theme\n".utf8)
        try external.write(to: fixture.managedURL)

        await #expect(throws: GhosttyAdapterError.self) {
            _ = try await adapter.apply(plan)
        }
        #expect(try Data(contentsOf: fixture.managedURL) == external)
    }

    @Test("Theme apply revalidates the parent after validation")
    func themeApplyRevalidatesParentAfterValidation() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let adapter = fixture.adapter()
        let connection = try await adapter.prepareConnection(instance: fixture.instance)
        _ = try await adapter.connect(connection)
        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: fixture.theme())
        await fixture.runtime.mutateParentDuringValidation(fixture.parentURL)

        await #expect(throws: GhosttyAdapterError.self) {
            _ = try await adapter.apply(plan)
        }
        #expect(try String(contentsOf: fixture.managedURL, encoding: .utf8) == "# Managed by Oh My Theme\n")
    }

    @Test("An upstream Ghostty artifact is applied byte-for-byte")
    func upstreamArtifactIsNotRegenerated() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let adapter = fixture.adapter()
        let connection = try await adapter.prepareConnection(instance: fixture.instance)
        _ = try await adapter.connect(connection)
        let upstream = Data("foreground = #abcdef\nbackground = #123456\n".utf8)
        let theme = PreparedTheme(
            variantID: Fixtures.pack.variants[0].qualifiedID,
            variant: Fixtures.pack.variants[0],
            sourceType: .upstream,
            sourceRevision: Fixtures.pack.source.revision,
            attribution: Fixtures.pack.source.attribution,
            themeSchemaVersion: Fixtures.pack.schemaVersion,
            contentDigest: Fixtures.pack.variants[0].contentDigest,
            compilerVersion: "theme-compiler-1",
            upstreamArtifact: upstream
        )

        let plan = try await adapter.prepareApply(instance: fixture.instance, theme: theme)
        _ = try await adapter.apply(plan)

        #expect(plan.artifact == upstream)
        #expect(try Data(contentsOf: fixture.managedURL) == upstream)
    }

    @Test("Durable Ghostty apply and undo restores the previous managed fragment")
    func durableThemeApplyAndUndo() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let store = try PersistenceStore(
            databaseURL: fixture.directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: fixture.directory.appendingPathComponent("recovery", isDirectory: true)
        )
        let adapter = fixture.adapter()
        let engine = ThemeEngine(packs: [Fixtures.pack], adapters: [adapter], persistence: store)
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let preview = try await engine.prepare(
            themeVariantID: Fixtures.pack.variants[0].qualifiedID,
            workspace: Workspace(
                id: .myMac,
                displayName: "My Mac",
                connectedTargetInstances: [fixture.instance]
            ))

        _ = try await engine.applyDurable(
            previewID: preview.id,
            workspace: Workspace(
                id: .myMac,
                displayName: "My Mac",
                connectedTargetInstances: [fixture.instance]
            )
        )
        let applied = try String(contentsOf: fixture.managedURL, encoding: .utf8)
        #expect(applied.contains("foreground = #112233"))

        let undo = try await engine.undoLast(workspace: .myMac)

        #expect(undo.outcomes[0].configurationState == .updated)
        #expect(undo.outcomes[0].runningInstanceReach == .reloadRequired)
        #expect(try String(contentsOf: fixture.managedURL, encoding: .utf8) == "# Managed by Oh My Theme\n")
    }

    @Test("Interrupted Ghostty apply recovers its receipt for a later undo")
    func interruptedThemeApplyRecoversReceipt() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let store = try PersistenceStore(
            databaseURL: fixture.directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: fixture.directory.appendingPathComponent("recovery", isDirectory: true)
        )
        let adapter = fixture.adapter()
        let engine = ThemeEngine(packs: [Fixtures.pack], adapters: [adapter], persistence: store)
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [fixture.instance]
        )
        let preview = try await engine.prepare(
            themeVariantID: Fixtures.pack.variants[0].qualifiedID, workspace: workspace)
        let apply = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        let appliedRecord = try #require(try store.journalLoadRecords(operationID: apply.operationID).first)
        try store.journalTransitionState(operationID: apply.operationID, to: .applying)
        try store.journalSaveRecord(
            JournaledRecord(
                operationID: appliedRecord.operationID,
                targetInstanceID: appliedRecord.targetInstanceID,
                ordinal: appliedRecord.ordinal,
                adapterID: appliedRecord.adapterID,
                adapterVersion: appliedRecord.adapterVersion,
                capabilityID: appliedRecord.capabilityID,
                phase: .applying,
                intendedChangeDigest: appliedRecord.intendedChangeDigest,
                staleStateToken: appliedRecord.staleStateToken,
                planDigest: appliedRecord.planDigest,
                receiptJSON: nil,
                detail: nil
            )
        )

        let relaunched = ThemeEngine(packs: [Fixtures.pack], adapters: [adapter], persistence: store)
        try await relaunched.reconcileInterruptedOperations()

        #expect(try store.journalLoadRecords(operationID: apply.operationID)[0].phase == .applied)
        let undo = try await relaunched.undoLast(workspace: workspace)
        #expect(undo.outcomes[0].configurationState == .updated)
        #expect(undo.outcomes[0].runningInstanceReach == .reloadRequired)
    }

    @Test("Interrupted recovery rejects a same-content external replacement")
    func interruptedThemeRecoveryRejectsSameContentReplacement() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let store = try PersistenceStore(
            databaseURL: fixture.directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: fixture.directory.appendingPathComponent("recovery", isDirectory: true)
        )
        let adapter = fixture.adapter()
        let engine = ThemeEngine(packs: [Fixtures.pack], adapters: [adapter], persistence: store)
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [fixture.instance]
        )
        let preview = try await engine.prepare(
            themeVariantID: Fixtures.pack.variants[0].qualifiedID, workspace: workspace)
        let apply = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        let appliedRecord = try #require(try store.journalLoadRecords(operationID: apply.operationID).first)
        let appliedBytes = try Data(contentsOf: fixture.managedURL)
        let replacement = fixture.directory.appendingPathComponent("same-content.ghostty")
        try appliedBytes.write(to: replacement)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: replacement.path
        )
        _ = try FileManager.default.replaceItemAt(fixture.managedURL, withItemAt: replacement)
        try store.journalTransitionState(operationID: apply.operationID, to: .applying)
        try store.journalSaveRecord(
            JournaledRecord(
                operationID: appliedRecord.operationID,
                targetInstanceID: appliedRecord.targetInstanceID,
                ordinal: appliedRecord.ordinal,
                adapterID: appliedRecord.adapterID,
                adapterVersion: appliedRecord.adapterVersion,
                capabilityID: appliedRecord.capabilityID,
                phase: .applying,
                intendedChangeDigest: appliedRecord.intendedChangeDigest,
                staleStateToken: appliedRecord.staleStateToken,
                planDigest: appliedRecord.planDigest,
                receiptJSON: nil,
                detail: nil
            )
        )

        try await engine.reconcileInterruptedOperations()

        #expect(try store.journalLoadRecords(operationID: apply.operationID)[0].phase == .reconciledConflict)
        await #expect(throws: DurableOperationError.self) {
            _ = try await engine.undoLast(workspace: workspace)
        }
        #expect(try Data(contentsOf: fixture.managedURL) == appliedBytes)
    }

    @Test("Undo reports a conflict and preserves an externally changed Ghostty fragment")
    func durableThemeUndoConflict() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let store = try PersistenceStore(
            databaseURL: fixture.directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: fixture.directory.appendingPathComponent("recovery", isDirectory: true)
        )
        let adapter = fixture.adapter()
        let engine = ThemeEngine(packs: [Fixtures.pack], adapters: [adapter], persistence: store)
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [fixture.instance]
        )
        let preview = try await engine.prepare(
            themeVariantID: Fixtures.pack.variants[0].qualifiedID, workspace: workspace)
        _ = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        let external = Data("# changed externally\n".utf8)
        try external.write(to: fixture.managedURL)

        let undo = try await engine.undoLast(workspace: workspace)

        #expect(undo.outcomes[0].configurationState == .conflicted)
        #expect(try Data(contentsOf: fixture.managedURL) == external)
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
        let store = try PersistenceStore(
            databaseURL: fixture.directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: fixture.directory.appendingPathComponent("recovery", isDirectory: true)
        )
        try store.saveWorkspace(.myMac)
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: store
        )
        let report = try await engine.connect(
            instance: fixture.instance,
            workspace: .myMac,
            approveLinkedSource: true,
            reviewedPlan: plan
        )

        #expect(report.outcomes.first?.configurationState == .updated)
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

    @Test("Restore and Disconnect restores the baseline and removes the durable connection")
    func engineDisconnect() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let adapter = fixture.adapter()
        let store = try PersistenceStore(
            databaseURL: fixture.directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: fixture.directory.appendingPathComponent("recovery", isDirectory: true)
        )
        try store.saveWorkspace(.myMac)
        let engine = ThemeEngine(packs: [], adapters: [adapter], persistence: store)
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)

        let report = try await engine.disconnect(instance: fixture.instance, workspace: .myMac)

        #expect(report.outcomes[0].configurationState == .updated)
        #expect(try store.loadWorkspace().workspace.connectedTargetInstances.isEmpty)
        #expect(try store.journalLoadConnectionBaseline(targetInstanceID: fixture.instance.id) == nil)
        #expect(try String(contentsOf: fixture.parentURL, encoding: .utf8) == "background = #101010\n")
        #expect(!FileManager.default.fileExists(atPath: fixture.managedURL.path))
    }

    @Test("Restore and Disconnect reports a conflict and keeps the Target connected after an external edit")
    func disconnectConflictReport() async throws {
        let fixture = try Fixture(parentContents: "background = #101010\n")
        let adapter = fixture.adapter()
        let store = try PersistenceStore(
            databaseURL: fixture.directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: fixture.directory.appendingPathComponent("recovery", isDirectory: true)
        )
        try store.saveWorkspace(.myMac)
        let engine = ThemeEngine(packs: [], adapters: [adapter], persistence: store)
        _ = try await engine.connect(instance: fixture.instance, workspace: .myMac)
        let external = "background = #303030\nconfig-file = ?oh-my-theme/config.ghostty\n"
        try Data(external.utf8).write(to: fixture.parentURL)

        let report = try await engine.disconnect(instance: fixture.instance, workspace: .myMac)

        #expect(report.outcomes[0].configurationState == .conflicted)
        #expect(report.outcomes[0].rollbackState == .blocked)
        #expect(try store.loadWorkspace().workspace.connectedTargetInstances == [fixture.instance])
        #expect(try store.journalLoadConnectionBaseline(targetInstanceID: fixture.instance.id) != nil)
        #expect(try String(contentsOf: fixture.parentURL, encoding: .utf8) == external)
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

        func theme() -> PreparedTheme {
            PreparedTheme(
                variantID: Fixtures.pack.variants[0].qualifiedID,
                variant: Fixtures.pack.variants[0],
                sourceType: .generated,
                sourceRevision: Fixtures.pack.source.revision,
                attribution: Fixtures.pack.source.attribution,
                themeSchemaVersion: Fixtures.pack.schemaVersion,
                contentDigest: Fixtures.pack.variants[0].contentDigest,
                compilerVersion: "theme-compiler-1",
                upstreamArtifact: nil
            )
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
    private var parentToMutateDuringValidation: URL?

    func mutateParentDuringValidation(_ url: URL) {
        parentToMutateDuringValidation = url
    }

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
        if let url = parentToMutateDuringValidation {
            try Data("background = #202020\n".utf8).write(to: url)
            parentToMutateDuringValidation = nil
        }
    }
}
