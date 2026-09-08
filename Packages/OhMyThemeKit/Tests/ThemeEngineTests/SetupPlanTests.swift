import Foundation
import Persistence
import Testing
import ThemeModel

@testable import ThemeEngine

@Suite("Aggregate Setup Plan (Issue #31)")
struct SetupPlanTests {
    private static func makeFixture() throws -> (directory: URL, store: PersistenceStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-setupplan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
        )
        return (directory, store)
    }

    @Test("Setup plan contains exact target instance IDs in stable execution order and performs zero writes")
    func setupPlanOrderAndZeroWrites() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let appearanceInstance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "macos.appearance"),
            displayName: "System Appearance",
            adapterID: "macos.appearance"
        )
        let wallpaperInstance1 = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "macos.wallpaper.1"),
            displayName: "Wallpaper (Display 1)",
            adapterID: "macos.wallpaper"
        )
        let wallpaperInstance2 = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "macos.wallpaper.2"),
            displayName: "Wallpaper (Display 2)",
            adapterID: "macos.wallpaper"
        )
        let starshipInstance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "starship.default"),
            displayName: "Starship",
            adapterID: "starship"
        )

        let adapter1 = RecordingWritableAdapter(
            id: "starship",
            activationReach: .nextPrompt,
            expectedSideEffects: ["Modify starship.toml"],
            requiredPermissions: []
        )
        let adapter2 = RecordingWritableAdapter(
            id: "macos.wallpaper",
            activationReach: .currentInstances,
            expectedSideEffects: ["Set desktop picture"],
            requiredPermissions: ["System Events"]
        )
        let adapter3 = RecordingWritableAdapter(
            id: "macos.appearance",
            activationReach: .currentInstances,
            expectedSideEffects: ["Set macOS dark mode"],
            requiredPermissions: ["AppleScript Automation"]
        )

        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter1, adapter2, adapter3],
            persistence: fixture.store
        )

        // Pass instances in arbitrary/scrambled order: starship, wallpaper2, appearance, wallpaper1
        let scrambledInstances = [starshipInstance, wallpaperInstance2, appearanceInstance, wallpaperInstance1]
        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: Set(scrambledInstances.map(\.id)),
            themeAssignment: nil
        )

        let plan = try await engine.prepareSetup(
            workspace: workspace,
            instances: scrambledInstances
        )

        // 1. Stable engine-owned execution order:
        // macos.appearance (0), macos.wallpaper (1), starship (4)
        #expect(plan.targetInstanceIDs == [
            appearanceInstance.id,
            wallpaperInstance1.id,
            wallpaperInstance2.id,
            starshipInstance.id
        ])
        #expect(plan.isFullyReady)
        #expect(plan.targetPlans.count == 4)
        #expect(plan.preparationFailures.isEmpty)

        // 2. Zero external writes performed and zero baselines stored
        for id in plan.targetInstanceIDs {
            let baseline = try fixture.store.journalLoadConnectionBaseline(targetInstanceID: id)
            #expect(baseline == nil)
        }

        // 3. Aggregate reach: worst of .currentInstances and .nextPrompt is .nextPrompt
        #expect(plan.activationReach == .nextPrompt)

        // 4. Aggregate permissions deduplicated
        #expect(plan.requiredPermissions.contains("AppleScript Automation"))
        #expect(plan.requiredPermissions.contains("System Events"))

        // 5. Shared effects grouped once for wallpapers
        let sharedWallpapers = plan.sharedEffects.first { $0.name == "Desktop Wallpaper Management" || $0.name == "Set desktop picture" }
        #expect(sharedWallpapers != nil)
        #expect(sharedWallpapers?.affectedTargetIDs.count == 2)
        #expect(sharedWallpapers?.affectedTargetIDs.contains(wallpaperInstance1.id) == true)
        #expect(sharedWallpapers?.affectedTargetIDs.contains(wallpaperInstance2.id) == true)

        // 6. Precondition validation on freshly prepared plan returns valid
        let validation = await engine.validateSetupPlanPreconditions(
            plan: plan,
            workspace: workspace,
            availableInstances: scrambledInstances
        )
        #expect(validation == .valid)
    }

    @Test("Setup plan captures preparation failure when adapter is missing and plan reflects it")
    func setupPlanCapturesPreparationFailures() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let validInstance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "valid.target"),
            displayName: "Valid Target",
            adapterID: "valid.adapter"
        )
        let missingInstance = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "missing.target"),
            displayName: "Missing Target",
            adapterID: "unavailable.adapter"
        )

        let adapter = RecordingWritableAdapter(id: "valid.adapter")
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter],
            persistence: fixture.store
        )

        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [validInstance.id, missingInstance.id],
            themeAssignment: nil
        )

        let plan = try await engine.prepareSetup(
            workspace: workspace,
            instances: [validInstance, missingInstance]
        )

        #expect(!plan.isFullyReady)
        #expect(plan.targetPlans.count == 1)
        #expect(plan.preparationFailures.count == 1)
        #expect(plan.preparationFailures[0].targetInstanceID == missingInstance.id)
        #expect(plan.preparationFailures[0].adapterID == "unavailable.adapter")
    }

    @Test("Material precondition changes invalidate the Setup Plan")
    func preconditionChangesInvalidateSetupPlan() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let instance1 = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "target1"),
            displayName: "Target 1",
            adapterID: "recording1"
        )
        let instance2 = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "target2"),
            displayName: "Target 2",
            adapterID: "recording2"
        )

        let adapter1 = RecordingWritableAdapter(id: "recording1")
        let adapter2 = RecordingWritableAdapter(id: "recording2")
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [adapter1, adapter2],
            persistence: fixture.store
        )

        let workspace = Workspace(
            id: WorkspaceID(rawValue: "test-ws"),
            displayName: "Test Workspace",
            connectedTargetInstances: [],
            targetOptIns: [instance1.id, instance2.id],
            themeAssignment: nil
        )

        let plan = try await engine.prepareSetup(
            workspace: workspace,
            instances: [instance1, instance2]
        )

        // Test 1: Changed Target Opt-ins invalidates
        let workspaceWithChangedOptIns = Workspace(
            id: workspace.id,
            displayName: workspace.displayName,
            connectedTargetInstances: [],
            targetOptIns: [instance1.id], // Opted out target2
            themeAssignment: nil
        )
        let optInValidation = await engine.validateSetupPlanPreconditions(
            plan: plan,
            workspace: workspaceWithChangedOptIns,
            availableInstances: [instance1, instance2]
        )
        guard case .invalidated(let reason) = optInValidation else {
            Issue.record("Expected validation to fail due to changed opt-ins")
            return
        }
        #expect(reason.contains("Opt-ins"))

        // Test 2: Target no longer available invalidates
        let discoveryValidation = await engine.validateSetupPlanPreconditions(
            plan: plan,
            workspace: workspace,
            availableInstances: [instance1] // instance2 disappeared
        )
        guard case .invalidated(let reason2) = discoveryValidation else {
            Issue.record("Expected validation to fail due to missing instance")
            return
        }
        #expect(reason2.contains("no longer available"))

        // Test 3: External configuration modified invalidates
        await adapter1.mutateWorldExternally(Data("externally modified".utf8))
        let configValidation = await engine.validateSetupPlanPreconditions(
            plan: plan,
            workspace: workspace,
            availableInstances: [instance1, instance2]
        )
        guard case .invalidated(let reason3) = configValidation else {
            Issue.record("Expected validation to fail due to external config modification")
            return
        }
        #expect(reason3.contains("externally modified"))
    }
}
