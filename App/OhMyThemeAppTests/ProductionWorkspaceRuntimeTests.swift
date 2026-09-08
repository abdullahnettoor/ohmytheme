import Foundation
import Persistence
import PlatformClients
import ThemeEngine
import ThemeModel
import XCTest

@testable import OhMyTheme

@MainActor
final class ProductionWorkspaceRuntimeTests: XCTestCase {
    private enum DiscoveryUnavailable: Error {
        case expectedInTest
    }

    private var temporaryDirectory: URL!
    private var persistence: PersistenceStore!
    private var store: WorkspaceStore!
    private var packs: [ThemePack]!

    override func setUp() async throws {
        try await super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-runtime-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        persistence = try PersistenceStore(
            databaseURL: temporaryDirectory.appendingPathComponent("workspace.sqlite"),
            contentStoreURL: temporaryDirectory.appendingPathComponent("Recovery", isDirectory: true)
        )
        store = WorkspaceStore(persistenceStore: persistence)
        packs = try BundledThemeCatalog().load()
    }

    override func tearDown() async throws {
        packs = nil
        store = nil
        persistence = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try await super.tearDown()
    }

    func testRuntimeExposesCurrentWorkspaceCatalogAndDiscoveredTargets() async throws {
        let runtime = makeRuntime()

        XCTAssertEqual(runtime.workspace.displayName, "My Mac")
        XCTAssertEqual(runtime.themePacks.map(\.displayName), ["Catppuccin", "Oh My Theme"])
        XCTAssertNil(runtime.persistenceError)
        XCTAssertTrue(runtime.canApplyThemes)

        let snapshot = try await runtime.start()

        XCTAssertEqual(snapshot.workspace.id, .myMac)
        XCTAssertTrue(snapshot.targets.contains { $0.id == "macos" })
    }

    func testRuntimePreservesStoredAppearancePairAcrossReload() throws {
        let pair = ThemeAssignment.appearancePair(
            lightVariantID: "catppuccin/mocha",
            darkVariantID: "oh-my-theme/aurora"
        )
        let customWorkspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [],
            themeAssignment: pair
        )
        try persistence.saveWorkspace(customWorkspace)

        let runtime = makeRuntime()
        XCTAssertEqual(runtime.workspace.themeAssignment, pair)

        let reloadedStore = WorkspaceStore(persistenceStore: persistence)
        let reloadedRuntime = ProductionWorkspaceRuntime(
            store: reloadedStore,
            themePacks: packs,
            targetDiscoveryProvider: {
                WorkspaceTargetDiscovery(
                    ghostty: .failure(DiscoveryUnavailable.expectedInTest),
                    wallpaper: .failure(DiscoveryUnavailable.expectedInTest),
                    starship: .failure(DiscoveryUnavailable.expectedInTest),
                    vscode: .failure(DiscoveryUnavailable.expectedInTest)
                )
            },
            vscodeCompanionBootstrap: { nil }
        )
        XCTAssertEqual(reloadedRuntime.workspace.themeAssignment, pair)

        let model = WorkspacePresentationModel(runtime: reloadedRuntime)
        XCTAssertNil(model.selectedThemeVariantID)
        XCTAssertNil(model.selectedThemePreview)
        XCTAssertEqual(model.desiredThemeTitle, "Choose a fixed Theme Variant")
        XCTAssertEqual(model.desiredThemeStatus, "Selection required")

        model.selectThemeVariant("catppuccin/mocha")
        XCTAssertEqual(model.selectedThemeVariantID, "catppuccin/mocha")
        XCTAssertEqual(
            reloadedStore.workspace.themeAssignment,
            .fixed(variantID: "catppuccin/mocha")
        )
        let persistedStore = WorkspaceStore(persistenceStore: persistence)
        XCTAssertEqual(
            persistedStore.workspace.themeAssignment,
            .fixed(variantID: "catppuccin/mocha")
        )
    }

    func testRuntimeSelectFixedThemeVariantPersistsThemeAssignment() throws {
        let runtime = makeRuntime()

        runtime.selectFixedThemeVariant("oh-my-theme/aurora")

        XCTAssertEqual(runtime.workspace.themeAssignment, .fixed(variantID: "oh-my-theme/aurora"))

        let reloadedStore = WorkspaceStore(persistenceStore: persistence)
        XCTAssertEqual(reloadedStore.workspace.themeAssignment, .fixed(variantID: "oh-my-theme/aurora"))
    }

    func testRuntimeConnectionReviewAndConnectRegistersBaselineAndUpdatesWorkspace() async throws {
        let adapter = RecordingWritableAdapter(id: "recording")
        let runtime = makeRuntime(additionalAdapters: [adapter])

        _ = try await runtime.start()

        let candidateID = TargetInstanceID(rawValue: "recording.default")
        _ = try await runtime.setTargetOptIn(instanceID: candidateID, isOptedIn: true)
        let reviewPlan = try await runtime.reviewConnection(optionID: candidateID)

        XCTAssertEqual(reviewPlan.targetInstanceID, candidateID)
        XCTAssertEqual(reviewPlan.adapterID, "recording")
        XCTAssertFalse(reviewPlan.requiresApproval)

        let connectionResult = try await runtime.connect(optionID: candidateID, reviewedPlan: reviewPlan)

        XCTAssertEqual(connectionResult.report.outcomes.first?.configurationState, .updated)
        XCTAssertTrue(runtime.workspace.connectedTargetInstances.contains { $0.id == candidateID })

        // Verify connected instance is durably recorded
        let reloadedWorkspace = store.workspace
        XCTAssertTrue(reloadedWorkspace.connectedTargetInstances.contains { $0.id == candidateID })
    }

    func testRuntimePreparesAndAppliesPlanDurablyWithRealEngineOrchestration() async throws {
        let adapter = RecordingWritableAdapter(id: "recording")
        let runtime = makeRuntime(additionalAdapters: [adapter])

        _ = try await runtime.start()
        runtime.selectFixedThemeVariant("catppuccin/mocha")

        let candidateID = TargetInstanceID(rawValue: "recording.default")
        _ = try await runtime.setTargetOptIn(instanceID: candidateID, isOptedIn: true)
        let reviewPlan = try await runtime.reviewConnection(optionID: candidateID)
        _ = try await runtime.connect(optionID: candidateID, reviewedPlan: reviewPlan)

        let initialAvailability = try await runtime.undoAvailability()
        XCTAssertEqual(initialAvailability, .unavailable)

        let plan = try await runtime.prepareApplyPlan()

        XCTAssertEqual(plan.variantID, "catppuccin/mocha")
        XCTAssertEqual(plan.targetPlans.count, 1)
        XCTAssertEqual(plan.targetPlans.first?.targetInstanceID, candidateID)

        let applyReport = try await runtime.apply(planID: plan.id)

        XCTAssertEqual(applyReport.variantID, plan.variantID)
        XCTAssertEqual(applyReport.outcomes.first?.configurationState, .updated)
        XCTAssertEqual(applyReport.outcomes.first?.rollbackState, .undoAvailable)

        let availabilityAfterApply = try await runtime.undoAvailability()
        guard case .available = availabilityAfterApply else {
            XCTFail("Expected .available, got \(availabilityAfterApply)")
            return
        }

        // Verify durable storage has the Last Apply Transaction recorded
        let lat = try persistence.journalFindLastAppliedTransaction(workspaceID: runtime.workspace.id)
        XCTAssertNotNil(lat)
        XCTAssertEqual(lat?.id, applyReport.operationID)
    }

    func testRuntimeUndoRestoresPreviousBaselineWithRealEngineOrchestration() async throws {
        let initialWorld = Data("baseline-before-theme".utf8)
        let adapter = RecordingWritableAdapter(id: "recording", initialWorld: initialWorld)
        let runtime = makeRuntime(additionalAdapters: [adapter])

        _ = try await runtime.start()
        runtime.selectFixedThemeVariant("catppuccin/mocha")

        let candidateID = TargetInstanceID(rawValue: "recording.default")
        _ = try await runtime.setTargetOptIn(instanceID: candidateID, isOptedIn: true)
        let reviewPlan = try await runtime.reviewConnection(optionID: candidateID)
        _ = try await runtime.connect(optionID: candidateID, reviewedPlan: reviewPlan)

        let plan = try await runtime.prepareApplyPlan()
        _ = try await runtime.apply(planID: plan.id)

        let bytesAfterApply = await adapter.currentWorldBytes()
        XCTAssertNotEqual(bytesAfterApply, initialWorld)

        let undoReport = try await runtime.undoLast()

        XCTAssertEqual(undoReport.outcomes.first?.rollbackState, .restored)
        let avail = try await runtime.undoAvailability()
        XCTAssertEqual(avail, .unavailable)

        let bytesAfterUndo = await adapter.currentWorldBytes()
        XCTAssertEqual(bytesAfterUndo, initialWorld + Data(".connected".utf8))
    }

    func testRuntimeRestoreAndDisconnectRemovesTargetAndRestoresBaseline() async throws {
        let initialWorld = Data("baseline-before-connect".utf8)
        let adapter = RecordingWritableAdapter(id: "recording", initialWorld: initialWorld)
        let runtime = makeRuntime(additionalAdapters: [adapter])

        _ = try await runtime.start()

        let candidateID = TargetInstanceID(rawValue: "recording.default")
        _ = try await runtime.setTargetOptIn(instanceID: candidateID, isOptedIn: true)
        let reviewPlan = try await runtime.reviewConnection(optionID: candidateID)
        _ = try await runtime.connect(optionID: candidateID, reviewedPlan: reviewPlan)

        XCTAssertTrue(runtime.workspace.connectedTargetInstances.contains { $0.id == candidateID })

        let disconnectResult = try await runtime.restoreAndDisconnect(targetInstanceID: candidateID)

        XCTAssertEqual(disconnectResult.report.outcomes.first?.configurationState, .updated)
        XCTAssertFalse(runtime.workspace.connectedTargetInstances.contains { $0.id == candidateID })
        XCTAssertFalse(store.workspace.connectedTargetInstances.contains { $0.id == candidateID })
        XCTAssertFalse(store.workspace.isOptedIn(candidateID))
        let restoredWorld = await adapter.currentWorldBytes()
        XCTAssertEqual(restoredWorld, initialWorld)
    }

    func testRuntimeStartupRecoveryClassifiesInterruptedAdapterMutation() async throws {
        let adapter = RecordingWritableAdapter(id: "recording")
        let runtime = makeRuntime(additionalAdapters: [adapter])
        _ = try await runtime.start()
        runtime.selectFixedThemeVariant("catppuccin/mocha")

        let candidateID = TargetInstanceID(rawValue: "recording.default")
        _ = try await runtime.setTargetOptIn(instanceID: candidateID, isOptedIn: true)
        let reviewPlan = try await runtime.reviewConnection(optionID: candidateID)
        _ = try await runtime.connect(optionID: candidateID, reviewedPlan: reviewPlan)
        let applyPlan = try await runtime.prepareApplyPlan()
        let targetPlan = try XCTUnwrap(applyPlan.targetPlans.first)

        _ = try await adapter.apply(targetPlan)
        let mutatedWorld = await adapter.currentWorldBytes()
        XCTAssertEqual(mutatedWorld, targetPlan.payload.payload)

        let interruptedOperation = try persistence.journalStartOperation(
            kind: .apply,
            workspaceID: store.workspace.id,
            variantID: applyPlan.variantID
        )
        let encodedPlan = try JSONEncoder().encode(targetPlan)
        let planReference = try persistence.journalStorePlanPayload(
            encodedPlan,
            ownerID: "operation:\(interruptedOperation.id.uuidString):recording"
        )
        try persistence.journalSaveRecord(
            JournaledRecord(
                operationID: interruptedOperation.id,
                targetInstanceID: candidateID,
                ordinal: 0,
                adapterID: targetPlan.adapterID,
                adapterVersion: targetPlan.adapterVersion,
                capabilityID: targetPlan.capabilityID,
                phase: .applying,
                intendedChangeDigest: targetPlan.intendedChangeDigest,
                staleStateToken: targetPlan.staleStateToken,
                planDigest: planReference.digest,
                receiptJSON: nil,
                detail: nil
            )
        )
        try persistence.journalTransitionState(operationID: interruptedOperation.id, to: .applying)

        let recoveringRuntime = makeRuntime(additionalAdapters: [adapter])
        let snapshot = try await recoveringRuntime.start()

        XCTAssertEqual(snapshot.workspace.id, .myMac)
        XCTAssertEqual(
            try persistence.journalLoadOperation(id: interruptedOperation.id)?.state,
            .reconciled
        )
        let records = try persistence.journalLoadRecords(operationID: interruptedOperation.id)
        XCTAssertEqual(records.first?.phase, .reconciledIntended)
        XCTAssertEqual(records.first?.detail, "reconciled:intendedAfterChange")
    }

    func testConnectionRequiresExplicitTargetOptIn() async throws {
        let adapter = RecordingWritableAdapter(id: "recording")
        let runtime = makeRuntime(additionalAdapters: [adapter])
        let candidateID = TargetInstanceID(rawValue: "recording.default")

        let initialSnapshot = try await runtime.start()
        let target = try XCTUnwrap(initialSnapshot.targets.first { $0.id == "recording" })
        XCTAssertTrue(target.connectionOptions.isEmpty)

        do {
            _ = try await runtime.reviewConnection(optionID: candidateID)
            XCTFail("Expected targetNotOptedIn")
        } catch ProductionWorkspaceRuntimeError.targetNotOptedIn(let id) {
            XCTAssertEqual(id, candidateID)
        }

        let optedInSnapshot = try await runtime.setTargetOptIn(instanceID: candidateID, isOptedIn: true)
        let optedInTarget = try XCTUnwrap(optedInSnapshot.targets.first { $0.id == "recording" })
        XCTAssertEqual(optedInTarget.connectionOptions.map(\.id), [candidateID])
        XCTAssertEqual(store.targetInstances.first { $0.id == candidateID }?.adapterID, "recording")
        _ = try await runtime.reviewConnection(optionID: candidateID)
    }

    func testFailedConnectionRefreshesDiscoveryBeforeReturning() async throws {
        let adapter = RecordingWritableAdapter(id: "recording")
        await adapter.setInterruption(.beforeConnect, enabled: true)
        var discoveryCalls = 0
        let runtime = ProductionWorkspaceRuntime(
            store: store,
            themePacks: packs,
            additionalAdapters: [adapter],
            targetDiscoveryProvider: {
                discoveryCalls += 1
                return WorkspaceTargetDiscovery(
                    ghostty: .failure(DiscoveryUnavailable.expectedInTest),
                    wallpaper: .failure(DiscoveryUnavailable.expectedInTest),
                    starship: .failure(DiscoveryUnavailable.expectedInTest),
                    vscode: .failure(DiscoveryUnavailable.expectedInTest)
                )
            },
            vscodeCompanionBootstrap: { nil }
        )
        let candidateID = TargetInstanceID(rawValue: "recording.default")

        _ = try await runtime.start()
        _ = try await runtime.setTargetOptIn(instanceID: candidateID, isOptedIn: true)
        let plan = try await runtime.reviewConnection(optionID: candidateID)
        let result = try await runtime.connect(optionID: candidateID, reviewedPlan: plan)

        XCTAssertFalse(result.snapshot.workspace.isConnected(candidateID))
        XCTAssertEqual(discoveryCalls, 4)
    }

    func testSelectAllRecommendedRefreshesEligibilityBeforePersistingOptIns() async throws {
        let installation = GhosttyInstallation(
            executableURL: URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            version: "1.3.1"
        )
        let configURL = URL(fileURLWithPath: "/tmp/ghostty/config")
        var discoveryCalls = 0
        let runtime = ProductionWorkspaceRuntime(
            store: store,
            themePacks: packs,
            targetDiscoveryProvider: {
                discoveryCalls += 1
                let report =
                    discoveryCalls == 1
                    ? GhosttyDiscoveryReport(
                        installations: [installation],
                        configurationCandidates: [configURL],
                        resolvedConfigurationURL: configURL
                    )
                    : GhosttyDiscoveryReport(installations: [])
                return WorkspaceTargetDiscovery(
                    ghostty: .success(report),
                    wallpaper: .failure(DiscoveryUnavailable.expectedInTest),
                    starship: .failure(DiscoveryUnavailable.expectedInTest),
                    vscode: .failure(DiscoveryUnavailable.expectedInTest)
                )
            },
            vscodeCompanionBootstrap: { nil }
        )

        let initialSnapshot = try await runtime.start()
        let initialGhostty = try XCTUnwrap(
            initialSnapshot.targets.first { $0.id == "ghostty" }?.instances.first
        )
        XCTAssertTrue(initialGhostty.isRecommended)

        let selectedSnapshot = try await runtime.selectAllRecommended()
        let refreshedGhostty = try XCTUnwrap(
            selectedSnapshot.targets.first { $0.id == "ghostty" }?.instances.first
        )
        XCTAssertEqual(discoveryCalls, 2)
        XCTAssertEqual(refreshedGhostty.exclusionReason, .unavailable)
        XCTAssertFalse(selectedSnapshot.workspace.isOptedIn(initialGhostty.id))
    }

    func testOptedInWallpaperRemainsVisibleWhenDisplayDisappears() async throws {
        let display = MacOSWallpaperConnectedDisplay(
            displayID: 42,
            currentImageURL: URL(fileURLWithPath: "/tmp/wallpaper.png"),
            currentPlacement: nil
        )
        var discoveryCalls = 0
        let pack = makeThemePackWithWallpaper()
        let runtime = ProductionWorkspaceRuntime(
            store: store,
            themePacks: [pack],
            targetDiscoveryProvider: {
                discoveryCalls += 1
                return WorkspaceTargetDiscovery(
                    ghostty: .failure(DiscoveryUnavailable.expectedInTest),
                    wallpaper: .success(
                        MacOSWallpaperDiscoveryReport(
                            displays: discoveryCalls == 1 ? [display] : []
                        )
                    ),
                    starship: .failure(DiscoveryUnavailable.expectedInTest),
                    vscode: .failure(DiscoveryUnavailable.expectedInTest)
                )
            },
            vscodeCompanionBootstrap: { nil }
        )

        runtime.selectFixedThemeVariant("pack-wallpaper/variant-wallpaper")
        let initialSnapshot = try await runtime.start()
        let wallpaperID = display.targetInstanceID
        let initialWallpaper = try XCTUnwrap(
            initialSnapshot.targets.first { $0.id == "macos" }?.instances.first { $0.id == wallpaperID }
        )
        XCTAssertTrue(initialWallpaper.isRecommended)

        _ = try await runtime.setTargetOptIn(instanceID: wallpaperID, isOptedIn: true)
        let refreshedSnapshot = try await runtime.refreshTargets()
        let unavailableWallpaper = try XCTUnwrap(
            refreshedSnapshot.targets.first { $0.id == "macos" }?.instances.first { $0.id == wallpaperID }
        )

        XCTAssertTrue(unavailableWallpaper.isOptedIn)
        XCTAssertEqual(unavailableWallpaper.managementState, .needsAttention)
        XCTAssertEqual(unavailableWallpaper.exclusionReason, .unavailable)

        let optedOutSnapshot = try await runtime.setTargetOptIn(instanceID: wallpaperID, isOptedIn: false)
        XCTAssertFalse(optedOutSnapshot.workspace.isOptedIn(wallpaperID))
    }

    func testUnavailableVSCodePreservesPersistedTargetIdentityAndIntent() async throws {
        let instance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "vscode:persisted:default"),
            displayName: "Visual Studio Code, Default profile",
            adapterID: "vscode"
        )
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [instance],
            targetOptIns: [instance.id]
        )
        try persistence.saveWorkspace(
            workspace,
            targetInstances: [
                PersistedTargetInstance(
                    id: instance.id,
                    displayName: instance.displayName,
                    adapterID: instance.adapterID,
                    isConnected: true,
                    isOptedIn: true
                )
            ]
        )
        let runtime = makeRuntime()

        let snapshot = try await runtime.start()
        let vscode = try XCTUnwrap(snapshot.targets.first { $0.id == "vscode" })
        let presented = try XCTUnwrap(vscode.instances.first { $0.id == instance.id })

        XCTAssertEqual(vscode.state, .needsAttention)
        XCTAssertTrue(presented.isConnected)
        XCTAssertTrue(presented.isOptedIn)
        XCTAssertEqual(presented.managementState, .needsAttention)
        XCTAssertEqual(presented.exclusionReason, .unavailable)
    }

    func testAmbiguousTargetCanBeOptedInWithoutBecomingConnectable() async throws {
        let installation = GhosttyInstallation(
            executableURL: URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
            version: "1.3.1"
        )
        let runtime = ProductionWorkspaceRuntime(
            store: store,
            themePacks: packs,
            targetDiscoveryProvider: {
                WorkspaceTargetDiscovery(
                    ghostty: .success(GhosttyDiscoveryReport(installations: [installation, installation])),
                    wallpaper: .failure(DiscoveryUnavailable.expectedInTest),
                    starship: .failure(DiscoveryUnavailable.expectedInTest),
                    vscode: .failure(DiscoveryUnavailable.expectedInTest)
                )
            },
            vscodeCompanionBootstrap: { nil }
        )

        let initialSnapshot = try await runtime.start()
        let instance = try XCTUnwrap(
            initialSnapshot.targets.first { $0.id == "ghostty" }?.instances.first
        )
        XCTAssertEqual(instance.exclusionReason, .ambiguous)
        XCTAssertTrue(
            initialSnapshot.targets.first { $0.id == "ghostty" }?.connectionOptions.isEmpty == true
        )

        let optedInSnapshot = try await runtime.setTargetOptIn(instanceID: instance.id, isOptedIn: true)
        let optedIn = try XCTUnwrap(
            optedInSnapshot.targets.first { $0.id == "ghostty" }?.instances.first
        )
        XCTAssertTrue(optedIn.isOptedIn)
        XCTAssertEqual(optedIn.managementState, .needsAttention)
        XCTAssertTrue(
            optedInSnapshot.targets.first { $0.id == "ghostty" }?.connectionOptions.isEmpty == true
        )
    }

    func testDiscoveryCreatesNoTargetOptInByItself() async throws {
        let runtime = makeRuntime()
        let snapshot = try await runtime.start()

        // Discovery alone creates no Target Opt-in
        XCTAssertTrue(runtime.workspace.targetOptIns.isEmpty)
        XCTAssertTrue(snapshot.workspace.targetOptIns.isEmpty)

        // All discovered unconnected targets start as NOT opted in
        for target in snapshot.targets {
            for instance in target.instances where !instance.isConnected {
                XCTAssertFalse(instance.isOptedIn)
            }
        }

        // Available unconnected targets start as .notSelected
        let macosTarget = try XCTUnwrap(snapshot.targets.first { $0.id == "macos" })
        let appearanceInstance = try XCTUnwrap(macosTarget.instances.first { $0.adapterID == "macos.appearance" })
        XCTAssertEqual(appearanceInstance.managementState, .notSelected)
    }

    func testSelectAllRecommendedPreservesConnectedNonRecommendedInstances() async throws {
        let connectedInstance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "custom_shell.default"),
            displayName: "Custom Shell",
            adapterID: "custom_shell"
        )
        try persistence.saveWorkspace(
            Workspace(
                id: .myMac,
                displayName: "My Mac",
                connectedTargetInstances: [connectedInstance],
                targetOptIns: [connectedInstance.id]
            ),
            targetInstances: [
                PersistedTargetInstance(
                    id: connectedInstance.id,
                    displayName: connectedInstance.displayName,
                    adapterID: connectedInstance.adapterID,
                    isConnected: true,
                    isOptedIn: true
                )
            ]
        )
        let adapter = RecordingWritableAdapter(id: "custom_shell")
        let runtime = makeRuntime(additionalAdapters: [adapter])

        _ = try await runtime.start()
        let snapshot = try await runtime.selectAllRecommended()

        XCTAssertTrue(snapshot.workspace.isConnected(connectedInstance.id))
        XCTAssertTrue(store.workspace.isConnected(connectedInstance.id))
        XCTAssertTrue(store.workspace.isOptedIn(connectedInstance.id))
    }

    func testSelectAllRecommendedSelectsOnlyAllowlistedRecommendedInstances() async throws {
        let nonAllowlisted = RecordingWritableAdapter(id: "custom_shell")
        let runtime = makeRuntime(additionalAdapters: [nonAllowlisted])

        let initialSnapshot = try await runtime.start()
        XCTAssertTrue(runtime.workspace.targetOptIns.isEmpty)

        // macos.appearance is allowlisted and recommended
        let macosTarget = try XCTUnwrap(initialSnapshot.targets.first { $0.id == "macos" })
        let appearanceInstance = try XCTUnwrap(macosTarget.instances.first { $0.adapterID == "macos.appearance" })
        XCTAssertTrue(appearanceInstance.isRecommended)

        // custom_shell is non-allowlisted and therefore NOT recommended
        let customTarget = try XCTUnwrap(initialSnapshot.targets.first { $0.id == "custom_shell" })
        let customInstance = try XCTUnwrap(customTarget.instances.first)
        XCTAssertFalse(customInstance.isRecommended)
        XCTAssertEqual(customInstance.exclusionReason, .nonAllowlisted)

        let snapshotAfterSelectAll = try await runtime.selectAllRecommended()

        // Recommended instances are now opted in
        XCTAssertTrue(snapshotAfterSelectAll.workspace.isOptedIn(appearanceInstance.id))
        XCTAssertTrue(runtime.workspace.isOptedIn(appearanceInstance.id))

        // Non-allowlisted instances remain NOT opted in
        XCTAssertFalse(snapshotAfterSelectAll.workspace.isOptedIn(customInstance.id))
        XCTAssertFalse(runtime.workspace.isOptedIn(customInstance.id))

        // And check persisted workspace
        let reloadedStore = WorkspaceStore(persistenceStore: persistence)
        XCTAssertTrue(reloadedStore.workspace.isOptedIn(appearanceInstance.id))
        XCTAssertFalse(reloadedStore.workspace.isOptedIn(customInstance.id))
    }

    func testCannotOptOutConnectedTargetWithoutDisconnect() async throws {
        let adapter = RecordingWritableAdapter(id: "recording")
        let runtime = makeRuntime(additionalAdapters: [adapter])

        _ = try await runtime.start()

        let candidateID = TargetInstanceID(rawValue: "recording.default")
        _ = try await runtime.setTargetOptIn(instanceID: candidateID, isOptedIn: true)
        let reviewPlan = try await runtime.reviewConnection(optionID: candidateID)
        _ = try await runtime.connect(optionID: candidateID, reviewedPlan: reviewPlan)

        XCTAssertTrue(runtime.workspace.isConnected(candidateID))
        XCTAssertTrue(runtime.workspace.isOptedIn(candidateID))

        // Attempting to opt out a connected target directly must throw cannotOptOutConnectedTarget
        do {
            _ = try await runtime.setTargetOptIn(instanceID: candidateID, isOptedIn: false)
            XCTFail("Expected cannotOptOutConnectedTarget error")
        } catch ProductionWorkspaceRuntimeError.cannotOptOutConnectedTarget(let id) {
            XCTAssertEqual(id, candidateID)
        }
    }

    func testExperimentalAdapterRemainsVisibleButIsNotRecommended() async throws {
        let adapterID = "experimental_shell"
        let adapter = RecordingWritableAdapter(id: adapterID)
        let runtime = makeRuntime(
            additionalAdapters: [adapter],
            experimentalAdapterIDs: [adapterID]
        )

        let snapshot = try await runtime.start()
        let target = try XCTUnwrap(snapshot.targets.first { $0.id == adapterID })
        let instance = try XCTUnwrap(target.instances.first)

        XCTAssertFalse(instance.isRecommended)
        XCTAssertEqual(instance.exclusionReason, .experimental)
    }

    func testSelectRecommendedSelectsOnlyTargetApplicationRecommendedInstances() async throws {
        let nonAllowlisted = RecordingWritableAdapter(id: "custom_shell")
        let runtime = makeRuntime(additionalAdapters: [nonAllowlisted])

        _ = try await runtime.start()

        let appearanceID = MacOSAppearanceAdapter.systemTargetInstanceID
        let customID = TargetInstanceID(rawValue: "custom_shell.default")

        // Select recommended for "macos"
        let snapshot = try await runtime.selectRecommended(applicationID: "macos")
        XCTAssertTrue(snapshot.workspace.isOptedIn(appearanceID))
        XCTAssertFalse(snapshot.workspace.isOptedIn(customID))
    }

    func testWallpaperDiscoveryWithNoDisplaysReportsNoDisplaysAndAppearanceRemainsIndependent() async throws {
        let pack = makeThemePackWithWallpaper()
        let runtime = ProductionWorkspaceRuntime(
            store: store,
            themePacks: [pack],
            targetDiscoveryProvider: {
                WorkspaceTargetDiscovery(
                    ghostty: .failure(DiscoveryUnavailable.expectedInTest),
                    wallpaper: .success(MacOSWallpaperDiscoveryReport(displays: [])),
                    starship: .failure(DiscoveryUnavailable.expectedInTest),
                    vscode: .failure(DiscoveryUnavailable.expectedInTest)
                )
            },
            vscodeCompanionBootstrap: { nil }
        )

        runtime.selectFixedThemeVariant("pack-wallpaper/variant-wallpaper")
        let snapshot = try await runtime.start()
        let macosTarget = try XCTUnwrap(snapshot.targets.first { $0.id == "macos" })
        XCTAssertTrue(macosTarget.summary.contains("No wallpaper displays discovered."))

        // Only System Appearance is in instances
        XCTAssertEqual(macosTarget.instances.count, 1)
        let appearance = macosTarget.instances[0]
        XCTAssertEqual(appearance.adapterID, "macos.appearance")
        XCTAssertTrue(appearance.isRecommended)
        XCTAssertFalse(appearance.isOptedIn)

        // Select All Recommended opts in System Appearance only
        let selected = try await runtime.selectAllRecommended()
        XCTAssertTrue(selected.workspace.isOptedIn(appearance.id))
        XCTAssertEqual(selected.workspace.targetOptIns.count, 1)
    }

    func testSingleWallpaperDisplayWithWallpaperThemeIsRecommendedAndSelectable() async throws {
        let display = MacOSWallpaperConnectedDisplay(
            displayID: 1,
            currentImageURL: URL(fileURLWithPath: "/tmp/wallpaper.png"),
            currentPlacement: nil
        )
        let pack = makeThemePackWithWallpaper()
        let runtime = ProductionWorkspaceRuntime(
            store: store,
            themePacks: [pack],
            targetDiscoveryProvider: {
                WorkspaceTargetDiscovery(
                    ghostty: .failure(DiscoveryUnavailable.expectedInTest),
                    wallpaper: .success(MacOSWallpaperDiscoveryReport(displays: [display])),
                    starship: .failure(DiscoveryUnavailable.expectedInTest),
                    vscode: .failure(DiscoveryUnavailable.expectedInTest)
                )
            },
            vscodeCompanionBootstrap: { nil }
        )

        runtime.selectFixedThemeVariant("pack-wallpaper/variant-wallpaper")
        let snapshot = try await runtime.start()
        let macosTarget = try XCTUnwrap(snapshot.targets.first { $0.id == "macos" })
        XCTAssertEqual(macosTarget.instances.count, 2)

        let appearance = try XCTUnwrap(macosTarget.instances.first { $0.adapterID == "macos.appearance" })
        let wallpaper = try XCTUnwrap(macosTarget.instances.first { $0.adapterID == "macos.wallpaper" })

        // Both are recommended when theme contains wallpaper
        XCTAssertTrue(appearance.isRecommended)
        XCTAssertTrue(wallpaper.isRecommended)
        XCTAssertNil(wallpaper.exclusionReason)

        // Neither is opted in initially
        XCTAssertFalse(appearance.isOptedIn)
        XCTAssertFalse(wallpaper.isOptedIn)

        // Independent opt-in: Opt into wallpaper display only
        let displayOptedInSnapshot = try await runtime.setTargetOptIn(instanceID: wallpaper.id, isOptedIn: true)
        XCTAssertTrue(displayOptedInSnapshot.workspace.isOptedIn(wallpaper.id))
        XCTAssertFalse(displayOptedInSnapshot.workspace.isOptedIn(appearance.id))

        // Independent opt-out: Opt out of wallpaper display
        let displayOptedOutSnapshot = try await runtime.setTargetOptIn(instanceID: wallpaper.id, isOptedIn: false)
        XCTAssertFalse(displayOptedOutSnapshot.workspace.isOptedIn(wallpaper.id))
        XCTAssertFalse(displayOptedOutSnapshot.workspace.isOptedIn(appearance.id))

        // Select All Recommended opts into both System Appearance and Display
        let allRecommendedSnapshot = try await runtime.selectAllRecommended()
        XCTAssertTrue(allRecommendedSnapshot.workspace.isOptedIn(appearance.id))
        XCTAssertTrue(allRecommendedSnapshot.workspace.isOptedIn(wallpaper.id))
    }

    func testSingleWallpaperDisplayWithThemeWithoutWallpaperIsExcludedFromRecommendation() async throws {
        let display = MacOSWallpaperConnectedDisplay(
            displayID: 1,
            currentImageURL: URL(fileURLWithPath: "/tmp/wallpaper.png"),
            currentPlacement: nil
        )
        let pack = makeThemePackWithoutWallpaper()
        let runtime = ProductionWorkspaceRuntime(
            store: store,
            themePacks: [pack],
            targetDiscoveryProvider: {
                WorkspaceTargetDiscovery(
                    ghostty: .failure(DiscoveryUnavailable.expectedInTest),
                    wallpaper: .success(MacOSWallpaperDiscoveryReport(displays: [display])),
                    starship: .failure(DiscoveryUnavailable.expectedInTest),
                    vscode: .failure(DiscoveryUnavailable.expectedInTest)
                )
            },
            vscodeCompanionBootstrap: { nil }
        )

        runtime.selectFixedThemeVariant("pack-plain/variant-plain")
        let snapshot = try await runtime.start()
        let macosTarget = try XCTUnwrap(snapshot.targets.first { $0.id == "macos" })

        let appearance = try XCTUnwrap(macosTarget.instances.first { $0.adapterID == "macos.appearance" })
        let wallpaper = try XCTUnwrap(macosTarget.instances.first { $0.adapterID == "macos.wallpaper" })

        // Appearance is recommended, but wallpaper display is excluded because theme has no wallpaper
        XCTAssertTrue(appearance.isRecommended)
        XCTAssertFalse(wallpaper.isRecommended)
        XCTAssertEqual(wallpaper.exclusionReason, .unavailable)
        XCTAssertEqual(wallpaper.exclusionDetail, "The selected theme does not contain a wallpaper.")

        // Wallpaper display can still be manually opted in by user intent
        let manualOptIn = try await runtime.setTargetOptIn(instanceID: wallpaper.id, isOptedIn: true)
        XCTAssertTrue(manualOptIn.workspace.isOptedIn(wallpaper.id))
        XCTAssertFalse(manualOptIn.workspace.isOptedIn(appearance.id))

        // Opt back out to test Select All Recommended
        _ = try await runtime.setTargetOptIn(instanceID: wallpaper.id, isOptedIn: false)

        // Select All Recommended opts in System Appearance but NOT the wallpaper display
        let selectedAll = try await runtime.selectAllRecommended()
        XCTAssertTrue(selectedAll.workspace.isOptedIn(appearance.id))
        XCTAssertFalse(selectedAll.workspace.isOptedIn(wallpaper.id))
    }

    func testAppearancePairUsesCurrentSystemAppearanceForWallpaperRecommendation() async throws {
        let display = MacOSWallpaperConnectedDisplay(
            displayID: 1,
            currentImageURL: URL(fileURLWithPath: "/tmp/wallpaper.png"),
            currentPlacement: nil
        )
        let pair = ThemeAssignment.appearancePair(
            lightVariantID: "pack-plain/variant-plain",
            darkVariantID: "pack-wallpaper/variant-wallpaper"
        )
        try persistence.saveWorkspace(
            Workspace(
                id: .myMac,
                displayName: "My Mac",
                connectedTargetInstances: [],
                themeAssignment: pair
            )
        )
        let discoveryProvider: WorkspaceTargetDiscoveryProvider = {
            WorkspaceTargetDiscovery(
                ghostty: .failure(DiscoveryUnavailable.expectedInTest),
                wallpaper: .success(MacOSWallpaperDiscoveryReport(displays: [display])),
                starship: .failure(DiscoveryUnavailable.expectedInTest),
                vscode: .failure(DiscoveryUnavailable.expectedInTest)
            )
        }
        let themePacks = [
            makeThemePackWithWallpaper(),
            makeThemePackWithoutWallpaper(appearance: .light),
        ]

        let lightRuntime = ProductionWorkspaceRuntime(
            store: store,
            themePacks: themePacks,
            targetDiscoveryProvider: discoveryProvider,
            currentThemeAppearanceProvider: { .light },
            vscodeCompanionBootstrap: { nil }
        )
        let lightSnapshot = try await lightRuntime.refreshTargets()
        let lightWallpaper = try XCTUnwrap(
            lightSnapshot.targets.first { $0.id == "macos" }?.instances.first {
                $0.id == display.targetInstanceID
            }
        )
        XCTAssertFalse(lightWallpaper.isRecommended)

        let darkRuntime = ProductionWorkspaceRuntime(
            store: store,
            themePacks: themePacks,
            targetDiscoveryProvider: discoveryProvider,
            currentThemeAppearanceProvider: { .dark },
            vscodeCompanionBootstrap: { nil }
        )
        let darkSnapshot = try await darkRuntime.refreshTargets()
        let darkWallpaper = try XCTUnwrap(
            darkSnapshot.targets.first { $0.id == "macos" }?.instances.first {
                $0.id == display.targetInstanceID
            }
        )
        XCTAssertTrue(darkWallpaper.isRecommended)
    }

    func testMultipleWallpaperDisplaysHaveIndependentOptInsAndSelection() async throws {
        let display1 = MacOSWallpaperConnectedDisplay(
            displayID: 1,
            currentImageURL: URL(fileURLWithPath: "/tmp/display1.png"),
            currentPlacement: nil
        )
        let display2 = MacOSWallpaperConnectedDisplay(
            displayID: 2,
            currentImageURL: URL(fileURLWithPath: "/tmp/display2.png"),
            currentPlacement: nil
        )
        let display3 = MacOSWallpaperConnectedDisplay(
            displayID: 3,
            currentImageURL: URL(fileURLWithPath: "/tmp/display3.png"),
            currentPlacement: nil
        )
        let packWithWallpaper = makeThemePackWithWallpaper()
        let packWithoutWallpaper = makeThemePackWithoutWallpaper()
        let runtime = ProductionWorkspaceRuntime(
            store: store,
            themePacks: [packWithWallpaper, packWithoutWallpaper],
            targetDiscoveryProvider: {
                WorkspaceTargetDiscovery(
                    ghostty: .failure(DiscoveryUnavailable.expectedInTest),
                    wallpaper: .success(MacOSWallpaperDiscoveryReport(displays: [display1, display2, display3])),
                    starship: .failure(DiscoveryUnavailable.expectedInTest),
                    vscode: .failure(DiscoveryUnavailable.expectedInTest)
                )
            },
            vscodeCompanionBootstrap: { nil }
        )

        runtime.selectFixedThemeVariant("pack-wallpaper/variant-wallpaper")
        let snapshot = try await runtime.start()
        let macosTarget = try XCTUnwrap(snapshot.targets.first { $0.id == "macos" })
        XCTAssertEqual(macosTarget.instances.count, 4)  // Appearance + 3 displays

        let appearanceID = MacOSAppearanceAdapter.systemTargetInstanceID
        let display1ID = display1.targetInstanceID
        let display2ID = display2.targetInstanceID
        let display3ID = display3.targetInstanceID

        // Opt in only Display 2
        let optIn2 = try await runtime.setTargetOptIn(instanceID: display2ID, isOptedIn: true)
        XCTAssertTrue(optIn2.workspace.isOptedIn(display2ID))
        XCTAssertFalse(optIn2.workspace.isOptedIn(display1ID))
        XCTAssertFalse(optIn2.workspace.isOptedIn(display3ID))
        XCTAssertFalse(optIn2.workspace.isOptedIn(appearanceID))

        // Select All Recommended opts into all remaining recommended instances
        let allOpted = try await runtime.selectAllRecommended()
        XCTAssertTrue(allOpted.workspace.isOptedIn(appearanceID))
        XCTAssertTrue(allOpted.workspace.isOptedIn(display1ID))
        XCTAssertTrue(allOpted.workspace.isOptedIn(display2ID))
        XCTAssertTrue(allOpted.workspace.isOptedIn(display3ID))

        // Switching to theme without wallpaper preserves opt-ins but excludes from recommendation
        runtime.selectFixedThemeVariant("pack-plain/variant-plain")
        let refreshed = try await runtime.refreshTargets()
        let refreshedMacos = try XCTUnwrap(refreshed.targets.first { $0.id == "macos" })
        for instance in refreshedMacos.instances where instance.adapterID == "macos.wallpaper" {
            XCTAssertFalse(instance.isRecommended)
            XCTAssertEqual(instance.exclusionReason, .unavailable)
            XCTAssertTrue(instance.isOptedIn)  // Existing opt-in survives theme change
        }
    }

    func testDisappearingDisplayBecomesUnavailableWithoutTransferringOptInToAnotherDisplay() async throws {
        let display1 = MacOSWallpaperConnectedDisplay(
            displayID: 1,
            currentImageURL: URL(fileURLWithPath: "/tmp/disp1.png"),
            currentPlacement: nil
        )
        let display2 = MacOSWallpaperConnectedDisplay(
            displayID: 2,
            currentImageURL: URL(fileURLWithPath: "/tmp/disp2.png"),
            currentPlacement: nil
        )
        var discoveryCalls = 0
        let pack = makeThemePackWithWallpaper()
        let runtime = ProductionWorkspaceRuntime(
            store: store,
            themePacks: [pack],
            targetDiscoveryProvider: {
                discoveryCalls += 1
                return WorkspaceTargetDiscovery(
                    ghostty: .failure(DiscoveryUnavailable.expectedInTest),
                    wallpaper: .success(
                        MacOSWallpaperDiscoveryReport(
                            displays: discoveryCalls == 1 ? [display1, display2] : [display2]
                        )
                    ),
                    starship: .failure(DiscoveryUnavailable.expectedInTest),
                    vscode: .failure(DiscoveryUnavailable.expectedInTest)
                )
            },
            vscodeCompanionBootstrap: { nil }
        )

        runtime.selectFixedThemeVariant("pack-wallpaper/variant-wallpaper")
        _ = try await runtime.start()
        let display1ID = display1.targetInstanceID
        let display2ID = display2.targetInstanceID

        // User opts in Display 1 only
        _ = try await runtime.setTargetOptIn(instanceID: display1ID, isOptedIn: true)
        XCTAssertTrue(runtime.workspace.isOptedIn(display1ID))
        XCTAssertFalse(runtime.workspace.isOptedIn(display2ID))

        // Display 1 disappears; Display 2 remains
        let refreshedSnapshot = try await runtime.refreshTargets()
        let macosTarget = try XCTUnwrap(refreshedSnapshot.targets.first { $0.id == "macos" })

        let item1 = try XCTUnwrap(macosTarget.instances.first { $0.id == display1ID })
        let item2 = try XCTUnwrap(macosTarget.instances.first { $0.id == display2ID })

        // Display 1 is unavailable and needs attention
        XCTAssertTrue(item1.isOptedIn)
        XCTAssertEqual(item1.managementState, .needsAttention)
        XCTAssertEqual(item1.exclusionReason, .unavailable)
        XCTAssertFalse(item1.isRecommended)

        // Display 2 did NOT inherit Display 1's opt-in!
        XCTAssertFalse(item2.isOptedIn)
        XCTAssertTrue(item2.isRecommended)
        XCTAssertNil(item2.exclusionReason)

        // Select All Recommended does NOT opt into unavailable Display 1, but opts into available Display 2
        let snapshotAfterSelect = try await runtime.selectAllRecommended()
        XCTAssertTrue(snapshotAfterSelect.workspace.isOptedIn(display1ID))  // preserved
        XCTAssertTrue(snapshotAfterSelect.workspace.isOptedIn(display2ID))  // newly selected
    }

    private func makeThemePackWithWallpaper() -> ThemePack {
        ThemePack(
            schemaVersion: 1,
            id: "pack-wallpaper",
            displayName: "Wallpaper Pack",
            author: "Tester",
            source: ThemeSource(
                type: .upstream,
                url: URL(string: "https://example.com")!,
                revision: "1.0",
                license: "MIT",
                attribution: "Tester"
            ),
            variants: [
                ThemeVariant(
                    id: "variant-wallpaper",
                    displayName: "Wallpaper Variant",
                    appearance: .dark,
                    contentDigest: "variant-digest",
                    roles: [:],
                    wallpaper: ThemeWallpaper(
                        assetPath: "test.jpg",
                        contentDigest: "wallpaper-digest",
                        attribution: "Test Attribution"
                    )
                )
            ]
        )
    }

    private func makeThemePackWithoutWallpaper(appearance: ThemeAppearance = .dark) -> ThemePack {
        ThemePack(
            schemaVersion: 1,
            id: "pack-plain",
            displayName: "Plain Pack",
            author: "Tester",
            source: ThemeSource(
                type: .upstream,
                url: URL(string: "https://example.com")!,
                revision: "1.0",
                license: "MIT",
                attribution: "Tester"
            ),
            variants: [
                ThemeVariant(
                    id: "variant-plain",
                    displayName: "Plain Variant",
                    appearance: appearance,
                    contentDigest: "variant-digest",
                    roles: [:],
                    wallpaper: nil
                )
            ]
        )
    }

    private func makeRuntime(
        additionalAdapters: [any ThemeAdapter] = [],
        experimentalAdapterIDs: Set<String> = []
    ) -> ProductionWorkspaceRuntime {
        ProductionWorkspaceRuntime(
            store: store,
            themePacks: packs,
            additionalAdapters: additionalAdapters,
            experimentalAdapterIDs: experimentalAdapterIDs,
            targetDiscoveryProvider: {
                WorkspaceTargetDiscovery(
                    ghostty: .failure(DiscoveryUnavailable.expectedInTest),
                    wallpaper: .failure(DiscoveryUnavailable.expectedInTest),
                    starship: .failure(DiscoveryUnavailable.expectedInTest),
                    vscode: .failure(DiscoveryUnavailable.expectedInTest)
                )
            },
            vscodeCompanionBootstrap: { nil }
        )
    }

    func testUnavailablePersistedTargetDoesNotSatisfySetupPlanAvailabilityValidation() async throws {
        let targetID = MacOSWallpaperAdapter.targetInstanceID(forDisplayID: 42)
        let instance = ConnectedTargetInstance(
            id: targetID,
            displayName: "Wallpaper (Display 42)",
            adapterID: "macos.wallpaper"
        )
        try persistence.saveWorkspace(
            Workspace(
                id: .myMac,
                displayName: "My Mac",
                connectedTargetInstances: [],
                targetOptIns: [targetID]
            ),
            targetInstances: [
                PersistedTargetInstance(
                    id: targetID,
                    displayName: instance.displayName,
                    adapterID: instance.adapterID,
                    isConnected: false,
                    isOptedIn: true
                )
            ]
        )
        let runtime = makeRuntime()
        let connectionPlan = ConnectionPlan(
            targetInstanceID: targetID,
            adapterID: instance.adapterID,
            adapterVersion: "1.0.0",
            capturedPreChangeState: Data("reviewed".utf8),
            intendedChangeDigest: "reviewed"
        )
        let setupPlan = SetupPlan(
            workspaceID: .myMac,
            targetInstanceIDs: [targetID],
            targetPlans: [connectionPlan],
            discoveryAndSelectionDigest: "reviewed"
        )

        let validation = await runtime.validateSetupPlanPreconditions(setupPlan)

        guard case .invalidated(let reason) = validation else {
            XCTFail("Expected the unavailable persisted display to invalidate the plan")
            return
        }
        XCTAssertTrue(reason.contains("no longer available"))
    }

    func testProductionWorkspaceRuntimePrepareSetupPlanAndValidation() async throws {
        let adapter = RecordingWritableAdapter(id: "recording")
        let runtime = makeRuntime(additionalAdapters: [adapter])
        let candidateID = TargetInstanceID(rawValue: "recording.default")

        _ = try await runtime.start()

        // Before opt-in, unresolved opted in list is empty -> prepareSetupPlan returns empty targets
        let emptyPlan = try await runtime.prepareSetupPlan()
        XCTAssertTrue(emptyPlan.targetInstanceIDs.isEmpty)
        XCTAssertTrue(emptyPlan.targetPlans.isEmpty)

        // Opt in candidate
        _ = try await runtime.setTargetOptIn(instanceID: candidateID, isOptedIn: true)

        let plan = try await runtime.prepareSetupPlan()
        XCTAssertEqual(plan.workspaceID, runtime.workspace.id)
        XCTAssertEqual(plan.targetInstanceIDs, [candidateID])
        XCTAssertEqual(plan.targetPlans.count, 1)
        XCTAssertTrue(plan.isFullyReady)

        // Validation against current state is valid
        let validation = await runtime.validateSetupPlanPreconditions(plan)
        XCTAssertEqual(validation, .valid)

        // Modify adapter externally -> validation fails with invalidation
        await adapter.mutateWorldExternally(Data("external-mutation".utf8))
        let invalidatedValidation = await runtime.validateSetupPlanPreconditions(plan)
        guard case .invalidated(let reason) = invalidatedValidation else {
            XCTFail("Expected invalidated validation")
            return
        }
        XCTAssertTrue(reason.contains("externally modified"))
    }
}
