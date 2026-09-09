import Foundation
import Persistence
import Testing
import ThemeModel

@testable import ThemeEngine

@Suite("Preflight Review (Issue #37)")
struct PreflightReviewTests {
    private struct Fixture {
        let store: PersistenceStore
        let directory: URL
    }

    private static func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-review-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
        )
        return Fixture(store: store, directory: directory)
    }

    // MARK: AC #1 & AC #5 — Review conditions stop before first mutation

    @Test("Conflicts, new ownership, new permissions, and ambiguous targets stop before first mutation")
    func preflightConditionsStopBeforeMutation() async throws {
        let target1 = TargetInstanceID(rawValue: "recording.target1")
        let target2 = TargetInstanceID(rawValue: "recording.target2")
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(id: target1, displayName: "Target 1", adapterID: "recording"),
                ConnectedTargetInstance(id: target2, displayName: "Target 2", adapterID: "recording"),
            ],
            themeAssignment: .fixed(variantID: "test-pack/dark")
        )

        // 1. Conflict plan
        let conflictPlan = ApplyPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: [target1],
            requiredThemeAssignment: workspace.themeAssignment,
            variantID: "test-pack/dark",
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Test",
            activationReach: .currentInstances,
            setupNeeds: [],
            conflicts: ["External edit conflict detected."],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [],
            preparationFailures: [],
            userActions: [],
            targetPlans: []
        )
        #expect(conflictPlan.hasReviewConditions)
        #expect(!conflictPlan.isClean)
        #expect(conflictPlan.preflightExplanation()?.contains("conflicts") == true)

        // 2. Ownership change plan
        let ownershipPlan = ApplyPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: [target1],
            requiredThemeAssignment: workspace.themeAssignment,
            variantID: "test-pack/dark",
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Test",
            activationReach: .currentInstances,
            setupNeeds: [],
            conflicts: [],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [],
            preparationFailures: [
                TargetPreparationFailure(
                    targetInstanceID: target1,
                    adapterID: "recording",
                    detail: "Target is managed by Nix; cannot plan writes."
                )
            ],
            userActions: [],
            targetPlans: []
        )
        #expect(ownershipPlan.hasReviewConditions)
        #expect(!ownershipPlan.isClean)
        #expect(ownershipPlan.preflightExplanation()?.contains("configuration ownership changes") == true)

        // 3. New permission plan
        let permissionPlan = ApplyPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: [target1],
            requiredThemeAssignment: workspace.themeAssignment,
            variantID: "test-pack/dark",
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Test",
            activationReach: .currentInstances,
            setupNeeds: [
                UserAction(title: "Permission needed", detail: "System Events automation permission required")
            ],
            conflicts: [],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [],
            preparationFailures: [],
            userActions: [],
            targetPlans: []
        )
        #expect(permissionPlan.hasReviewConditions)
        #expect(!permissionPlan.isClean)
        #expect(permissionPlan.preflightExplanation()?.contains("new permissions") == true)

        // 4. Ambiguous target plan
        let ambiguousPlan = ApplyPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: [target1],
            requiredThemeAssignment: workspace.themeAssignment,
            variantID: "test-pack/dark",
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Test",
            activationReach: .currentInstances,
            setupNeeds: [],
            conflicts: [],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [],
            preparationFailures: [
                TargetPreparationFailure(
                    targetInstanceID: target1,
                    adapterID: "recording",
                    detail: "Ambiguous configuration detected."
                )
            ],
            userActions: [],
            targetPlans: []
        )
        #expect(ambiguousPlan.hasReviewConditions)
        #expect(!ambiguousPlan.isClean)
        #expect(ambiguousPlan.preflightExplanation()?.contains("ambiguous configuration") == true)
    }

    // MARK: AC #2 — Review identifies affected targets and explains why continuation stopped

    @Test("Review identifies affected targets and reasons")
    func reviewIdentifiesAffectedTargetsAndReasons() async throws {
        let targetA = TargetInstanceID(rawValue: "recording.a")
        let targetB = TargetInstanceID(rawValue: "recording.b")

        let plan = ApplyPlan(
            id: UUID(),
            workspaceID: .myMac,
            targetInstanceIDs: [targetA, targetB],
            requiredThemeAssignment: .fixed(variantID: "test-pack/dark"),
            variantID: "test-pack/dark",
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Test",
            activationReach: .currentInstances,
            setupNeeds: [],
            conflicts: [],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [],
            preparationFailures: [
                TargetPreparationFailure(
                    targetInstanceID: targetB,
                    adapterID: "recording",
                    detail: "Target is linked and requires approval."
                )
            ],
            userActions: [],
            targetPlans: [
                AdapterPlan(
                    targetInstanceID: targetA,
                    adapterID: "recording",
                    adapterVersion: "1",
                    capabilityID: "theme",
                    payload: AdapterPayloadEnvelope(
                        adapterID: "recording",
                        adapterVersion: "1",
                        payloadVersion: "1",
                        payload: Data("payload-a".utf8)
                    ),
                    intendedChangeDigest: "digest-a",
                    capturedPreChangeState: Data("pre-a".utf8),
                    staleStateToken: "token-a",
                    expectedSideEffects: [],
                    requiredPermissions: [],
                    sourceType: .upstream,
                    sourceRevision: "1",
                    activationReach: .currentInstances,
                    setupNeeds: [],
                    conflicts: []
                )
            ]
        )

        let reasons = plan.preflightReviewReasons()
        #expect(reasons.count == 1)
        #expect(reasons.first?.targetInstanceID == targetB)
        #expect(reasons.first?.category == .ownership)

        let explanation = plan.preflightExplanation()
        #expect(explanation != nil)
        #expect(explanation?.contains("1 Target Instance requires review") == true)
        #expect(explanation?.contains("configuration ownership changes") == true)

        #expect(plan.readyTargetInstanceIDs == [targetA])
    }

    // MARK: AC #3 — Apply to ready targets creates explicit partial apply transaction

    @Test("Apply to ready targets mutates only ready instances and records unready outcomes honestly")
    func applyToReadyTargetsMutatesOnlyReadyInstances() async throws {
        let fixture = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let readyTargetID = TargetInstanceID(rawValue: "recording.ready")
        let conflictedTargetID = TargetInstanceID(rawValue: "recording.conflicted")

        let readyAdapter = RecordingWritableAdapter(
            id: "ready-adapter",
            initialWorld: Data("ready-before".utf8)
        )
        let conflictedAdapter = RecordingWritableAdapter(
            id: "conflicted-adapter",
            initialWorld: Data("conflicted-before".utf8)
        )

        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [readyAdapter, conflictedAdapter],
            persistence: fixture.store
        )

        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(id: readyTargetID, displayName: "Ready Target", adapterID: "ready-adapter"),
                ConnectedTargetInstance(id: conflictedTargetID, displayName: "Conflicted Target", adapterID: "conflicted-adapter"),
            ],
            themeAssignment: .fixed(variantID: "test-pack/dark")
        )
        try fixture.store.saveWorkspace(workspace)

        // Create an ApplyPlan where one target is ready and the other has a preflight conflict
        let readyPlan = AdapterPlan(
            targetInstanceID: readyTargetID,
            adapterID: "ready-adapter",
            adapterVersion: "1",
            capabilityID: "theme",
            payload: AdapterPayloadEnvelope(
                adapterID: "ready-adapter",
                adapterVersion: "1",
                payloadVersion: "1",
                payload: Data("ready-theme".utf8)
            ),
            intendedChangeDigest: "ready-digest",
            capturedPreChangeState: Data("ready-before".utf8),
            staleStateToken: "rev-0",
            expectedSideEffects: [],
            requiredPermissions: [],
            sourceType: .upstream,
            sourceRevision: "1",
            activationReach: .currentInstances,
            setupNeeds: [],
            conflicts: []
        )

        let conflictedPlan = AdapterPlan(
            targetInstanceID: conflictedTargetID,
            adapterID: "conflicted-adapter",
            adapterVersion: "1",
            capabilityID: "theme",
            payload: AdapterPayloadEnvelope(
                adapterID: "conflicted-adapter",
                adapterVersion: "1",
                payloadVersion: "1",
                payload: Data("conflicted-theme".utf8)
            ),
            intendedChangeDigest: "conflicted-digest",
            capturedPreChangeState: Data("conflicted-before".utf8),
            staleStateToken: "token-conflicted",
            expectedSideEffects: [],
            requiredPermissions: [],
            sourceType: .upstream,
            sourceRevision: "1",
            activationReach: .currentInstances,
            setupNeeds: [],
            conflicts: ["External edit conflict detected before apply."]
        )

        let orderedTargetIDs = WorkspaceTargetOrder.ordered(workspace.connectedTargetInstances).map(\.id)
        let targetPlans = orderedTargetIDs.map { id in
            id == readyTargetID ? readyPlan : conflictedPlan
        }

        let plan = ApplyPlan(
            id: UUID(),
            workspaceID: workspace.id,
            targetInstanceIDs: orderedTargetIDs,
            requiredThemeAssignment: workspace.themeAssignment,
            variantID: "test-pack/dark",
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Test",
            activationReach: .currentInstances,
            setupNeeds: [],
            conflicts: [],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [],
            preparationFailures: [],
            userActions: [],
            targetPlans: targetPlans
        )

        // Store plan in flight in engine
        await engine.storePlanInFlight(plan)

        // Execute Apply to ready targets via engine.applyDurable
        let report = try await engine.applyDurable(planID: plan.id, workspace: workspace)

        // Verify outcomes
        let readyOutcome = report.outcomes.first { $0.targetInstanceID == readyTargetID }
        let conflictedOutcome = report.outcomes.first { $0.targetInstanceID == conflictedTargetID }

        #expect(readyOutcome?.configurationState == .updated)
        #expect(readyOutcome?.rollbackState == .undoAvailable)

        #expect(conflictedOutcome?.configurationState == .conflicted)
        #expect(conflictedOutcome?.rollbackState == .blocked)

        // Verify mutation occurred ONLY on ready target, conflicted target was untouched
        #expect(await readyAdapter.currentWorldBytes() == Data("ready-theme".utf8))
        #expect(await conflictedAdapter.currentWorldBytes() == Data("conflicted-before".utf8))

        // Verify Undo availability is available for the changed target
        let undo = try await engine.undoAvailability(workspace: workspace)
        #expect(undo == .available(sourceOperationID: report.operationID, changedTargetCount: 1))
    }

    // MARK: AC #4 — Previously acknowledged unavailable targets and documented reach do not block routine apply

    @Test("Documented reach requirements and previously acknowledged unavailable targets do not block routine apply")
    func acknowledgedUnavailableAndReachDoNotBlock() async throws {
        let readyTargetID = TargetInstanceID(rawValue: "recording.ready")
        let unavailableTargetID = TargetInstanceID(rawValue: "recording.unavailable")

        // 1. Plan with reloadRequired and nextPrompt documented reach
        let cleanReachPlan = ApplyPlan(
            id: UUID(),
            workspaceID: .myMac,
            targetInstanceIDs: [readyTargetID],
            requiredThemeAssignment: .fixed(variantID: "test-pack/dark"),
            variantID: "test-pack/dark",
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Test",
            activationReach: .reloadRequired,
            setupNeeds: [],
            conflicts: [],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [],
            preparationFailures: [],
            userActions: [],
            targetPlans: [
                AdapterPlan(
                    targetInstanceID: readyTargetID,
                    adapterID: "recording",
                    adapterVersion: "1",
                    capabilityID: "theme",
                    payload: AdapterPayloadEnvelope(
                        adapterID: "recording",
                        adapterVersion: "1",
                        payloadVersion: "1",
                        payload: Data("theme".utf8)
                    ),
                    intendedChangeDigest: "digest",
                    capturedPreChangeState: Data("pre".utf8),
                    staleStateToken: "token",
                    expectedSideEffects: [],
                    requiredPermissions: ["Write config"],
                    sourceType: .upstream,
                    sourceRevision: "1",
                    activationReach: .nextPrompt,
                    setupNeeds: [],
                    conflicts: []
                )
            ]
        )
        #expect(!cleanReachPlan.hasReviewConditions)
        #expect(cleanReachPlan.isClean)

        // 2. Plan with an unacknowledged unavailable target
        let unackPlan = ApplyPlan(
            id: UUID(),
            workspaceID: .myMac,
            targetInstanceIDs: [readyTargetID, unavailableTargetID],
            requiredThemeAssignment: .fixed(variantID: "test-pack/dark"),
            variantID: "test-pack/dark",
            sourceType: .upstream,
            sourceRevision: "1",
            attribution: "Test",
            activationReach: .currentInstances,
            setupNeeds: [],
            conflicts: [],
            unavailableCapabilities: [],
            unavailableTargetInstanceIDs: [unavailableTargetID],
            preparationFailures: [],
            userActions: [],
            targetPlans: cleanReachPlan.targetPlans
        )
        #expect(unackPlan.hasReviewConditions(acknowledgedUnavailableTargets: []))
        #expect(!unackPlan.isClean(acknowledgedUnavailableTargets: []))

        // 3. Once acknowledged, it does not block routine apply
        let acknowledged: Set<TargetInstanceID> = [unavailableTargetID]
        #expect(!unackPlan.hasReviewConditions(acknowledgedUnavailableTargets: acknowledged))
        #expect(unackPlan.isClean(acknowledgedUnavailableTargets: acknowledged))
    }
}
