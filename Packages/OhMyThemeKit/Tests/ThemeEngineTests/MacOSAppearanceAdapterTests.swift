import Foundation
import Persistence
import PlatformClients
import Testing
import ThemeModel

@testable import ThemeEngine

@Suite("macOS appearance adapter (issue #18)")
struct MacOSAppearanceAdapterTests {
    @Test("Discovery explains Automation permission before System Events is contacted")
    func discoveryExplainsPermissionWithoutReadingAppearance() async throws {
        let platform = RecordingAppearancePlatform(initialDarkMode: false)
        let adapter = MacOSAppearanceAdapter(platform: platform)

        let report = await adapter.discover()

        #expect(report.targetInstanceID == MacOSAppearanceAdapter.systemTargetInstanceID)
        #expect(report.requiredPermissions == [MacOSAppearanceAdapter.automationPermissionDescription])
        #expect(platform.readCount == 0)
        #expect(platform.applyCalls.isEmpty)
    }

    @Test("Connection records the system appearance and permission requirement without changing it")
    func connectionRecordsBaseline() async throws {
        let fixture = AppearanceFixture(initialDarkMode: false)

        let plan = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        let baseline = try JSONDecoder().decode(AppearanceSnapshot.self, from: plan.capturedPreChangeState)
        let receipt = try await fixture.adapter.connect(plan)

        #expect(baseline == AppearanceSnapshot(darkMode: false))
        #expect(plan.requiredPermissions == [MacOSAppearanceAdapter.automationPermissionDescription])
        #expect(receipt.configurationState == .unchanged)
        #expect(receipt.detail?.contains("Automation access is available") == true)
        #expect(fixture.platform.applyCalls.isEmpty)
    }

    @Test("Connection recovery refuses a persisted plan from another adapter version")
    func connectionRejectsIncompatibleVersion() async throws {
        let fixture = AppearanceFixture(initialDarkMode: false)
        let current = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        let incompatible = ConnectionPlan(
            targetInstanceID: current.targetInstanceID,
            adapterID: current.adapterID,
            adapterVersion: "0.9.0",
            capturedPreChangeState: current.capturedPreChangeState,
            intendedChangeDigest: current.intendedChangeDigest,
            staleStateToken: current.staleStateToken,
            expectedSideEffects: current.expectedSideEffects,
            requiredPermissions: current.requiredPermissions,
            userActions: current.userActions,
            opaquePayload: current.opaquePayload,
            requiresApproval: current.requiresApproval
        )

        await #expect(throws: MacOSAppearanceAdapterError.malformedPlan) {
            _ = try await fixture.adapter.classifyConnection(plan: incompatible)
        }
    }

    @Test("Connection denial is a distinct permission-denied adapter outcome")
    func connectionReportsPermissionDenial() async throws {
        let fixture = AppearanceFixture(initialDarkMode: false)
        fixture.platform.readFailure = AppleScriptFailure.notAuthorized

        await #expect(throws: MacOSAppearanceAdapterError.permissionDenied) {
            _ = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        }
    }

    @Test("Apply preparation maps the Theme Variant appearance and survives restart serialization")
    func applyPlanMapsVariantAndRoundTrips() async throws {
        let fixture = AppearanceFixture(initialDarkMode: true)

        let plan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.preparedTheme(appearance: .light)
        )
        let payload = try JSONDecoder().decode(MacOSAppearanceApplyPayload.self, from: plan.payload.payload)
        let reloaded = try JSONDecoder().decode(AdapterPlan.self, from: JSONEncoder().encode(plan))

        #expect(payload.intended == AppearanceSnapshot(darkMode: false))
        #expect(plan.capabilityID == "appearance")
        #expect(plan.activationReach == .currentInstances)
        #expect(plan.requiredPermissions == [MacOSAppearanceAdapter.automationPermissionDescription])
        #expect(reloaded == plan)
    }

    @Test("Apply preparation captures current state rather than the Connection Baseline")
    func applyUsesPreApplyStateForRollback() async throws {
        let fixture = AppearanceFixture(initialDarkMode: true)
        let connectionBaseline = try JSONEncoder().encode(AppearanceSnapshot(darkMode: false))

        let plan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.preparedTheme(appearance: .light),
            connectionBaseline: connectionBaseline
        )
        let payload = try JSONDecoder().decode(MacOSAppearanceApplyPayload.self, from: plan.payload.payload)

        #expect(payload.baseline == AppearanceSnapshot(darkMode: true))
    }

    @Test("Apply changes Light to Dark and stores the prior state for Undo")
    func applyStoresRollbackState() async throws {
        let fixture = AppearanceFixture(initialDarkMode: false)
        let plan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.preparedTheme(appearance: .dark)
        )

        let receipt = try await fixture.adapter.apply(plan)
        let rollback = try #require(receipt.rollbackData)
        let payload = try JSONDecoder().decode(MacOSAppearanceApplyPayload.self, from: rollback)

        #expect(receipt.configurationState == .updated)
        #expect(payload.baseline == AppearanceSnapshot(darkMode: false))
        #expect(payload.intended == AppearanceSnapshot(darkMode: true))
        #expect(fixture.platform.currentSnapshot == AppearanceSnapshot(darkMode: true))
    }

    @Test("Apply reports unchanged separately and does not send a setter")
    func applyReportsUnchanged() async throws {
        let fixture = AppearanceFixture(initialDarkMode: true)
        let plan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.preparedTheme(appearance: .dark)
        )

        let receipt = try await fixture.adapter.apply(plan)

        #expect(receipt.configurationState == .unchanged)
        #expect(fixture.platform.applyCalls.isEmpty)
    }

    @Test("Revoked Automation access is preserved as a distinct apply outcome")
    func applyReportsRevokedPermission() async throws {
        let fixture = AppearanceFixture(initialDarkMode: false)
        fixture.platform.readFailure = AppleScriptFailure.notAuthorized
        let plan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.preparedTheme(appearance: .dark)
        )

        await #expect(throws: MacOSAppearanceAdapterError.permissionRevoked) {
            _ = try await fixture.adapter.apply(plan)
        }
        #expect(fixture.platform.applyCalls.isEmpty)
    }

    @Test("A System Events outage is distinct from permission denial")
    func applyReportsTargetUnavailable() async throws {
        let fixture = AppearanceFixture(initialDarkMode: false)
        fixture.platform.readFailure = AppleScriptFailure.targetUnavailable
        let plan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.preparedTheme(appearance: .dark)
        )

        await #expect(throws: MacOSAppearanceAdapterError.targetUnavailable) {
            _ = try await fixture.adapter.apply(plan)
        }
    }

    @Test("A failed post-write verification is distinct from unchanged")
    func applyReportsVerificationFailure() async throws {
        let fixture = AppearanceFixture(initialDarkMode: false)
        let plan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.preparedTheme(appearance: .dark)
        )
        fixture.platform.applyResultOverride = .verificationFailed(
            previous: AppearanceSnapshot(darkMode: false),
            expected: AppearanceSnapshot(darkMode: true),
            observed: AppearanceSnapshot(darkMode: false)
        )

        await #expect(
            throws: MacOSAppearanceAdapterError.verificationFailed(
                expected: AppearanceSnapshot(darkMode: true),
                observed: AppearanceSnapshot(darkMode: false)
            )
        ) {
            _ = try await fixture.adapter.apply(plan)
        }
    }

    @Test("Apply is idempotent when the intended appearance is already current")
    func applyAcceptsIntendedAppearanceReachedAfterPreview() async throws {
        let fixture = AppearanceFixture(initialDarkMode: false)
        let plan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.preparedTheme(appearance: .dark)
        )
        fixture.platform.replaceCurrent(darkMode: true)

        let receipt = try await fixture.adapter.apply(plan)

        #expect(receipt.configurationState == .unchanged)
        #expect(fixture.platform.applyCalls.isEmpty)
    }

    @Test("Recovery preserves an unchanged result when baseline already equals intent")
    func recoveryPreservesUnchangedResult() async throws {
        let fixture = AppearanceFixture(initialDarkMode: true)
        let plan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.preparedTheme(appearance: .dark)
        )

        let recovered = try await fixture.adapter.recoverApplyReceipt(plan: plan)

        #expect(recovered.configurationState == .unchanged)
        #expect(fixture.platform.applyCalls.isEmpty)
    }

    @Test("Recovery recreates an Undo-capable receipt after a successful appearance write")
    func recoveryRecreatesReceipt() async throws {
        let fixture = AppearanceFixture(initialDarkMode: false)
        let plan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.preparedTheme(appearance: .dark)
        )
        _ = try await fixture.adapter.apply(plan)

        let recovered = try await fixture.adapter.recoverApplyReceipt(plan: plan)
        try await fixture.adapter.rollbackApply(plan: plan, receipt: recovered)

        #expect(recovered.rollbackData != nil)
        #expect(fixture.platform.currentSnapshot == AppearanceSnapshot(darkMode: false))
    }

    @Test("Disconnect requires Undo to restore the Connection Baseline first")
    func disconnectRequiresBaseline() async throws {
        let fixture = AppearanceFixture(initialDarkMode: false)
        let connectionPlan = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        _ = try await fixture.adapter.connect(connectionPlan)
        let applyPlan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.preparedTheme(appearance: .dark)
        )
        let applyReceipt = try await fixture.adapter.apply(applyPlan)
        let stored = StoredConnectionBaseline(
            targetInstanceID: fixture.instance.id,
            adapterID: "macos.appearance",
            adapterVersion: "1.0.0",
            baselineReference: ContentReference(digest: "baseline", byteCount: 1),
            capturedAt: Date()
        )

        await #expect(throws: MacOSAppearanceAdapterError.restorationConflict) {
            _ = try await fixture.adapter.prepareDisconnect(
                instance: fixture.instance,
                baseline: stored,
                baselineData: connectionPlan.capturedPreChangeState
            )
        }

        try await fixture.adapter.rollbackApply(plan: applyPlan, receipt: applyReceipt)
        let disconnectPlan = try await fixture.adapter.prepareDisconnect(
            instance: fixture.instance,
            baseline: stored,
            baselineData: connectionPlan.capturedPreChangeState
        )
        let receipt = try await fixture.adapter.disconnect(
            disconnectPlan,
            baseline: connectionPlan.capturedPreChangeState
        )

        #expect(receipt.configurationState == .unchanged)
        #expect(fixture.platform.applyCalls == [true, false])
    }

    @Test("An unrelated Target Instance ID is refused before System Events is contacted")
    func unsupportedInstanceIsRefused() async throws {
        let fixture = AppearanceFixture(initialDarkMode: false)
        let unsupported = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "macos.appearance:other"),
            displayName: "Other",
            adapterID: "macos.appearance"
        )

        await #expect(throws: MacOSAppearanceAdapterError.unsupportedInstance(unsupported.id)) {
            _ = try await fixture.adapter.prepareConnection(instance: unsupported)
        }
        #expect(fixture.platform.readCount == 0)
    }

    @Test("A denied connection becomes a permission-required Capability Outcome")
    func deniedConnectionOutcome() async throws {
        let fixture = AppearanceFixture(initialDarkMode: false)
        fixture.platform.readFailure = AppleScriptFailure.notAuthorized
        let durable = try DurableAppearanceFixture()
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [fixture.adapter],
            persistence: durable.store
        )

        let report = try await engine.connect(
            instance: fixture.instance,
            workspace: durable.workspace(instances: [])
        )

        #expect(report.outcomes[0].configurationState == .permissionRequired)
        #expect(report.outcomes[0].detail?.contains("denied") == true)
    }

    @Test("Revoked Automation access does not stop a sibling Target Instance")
    func revocationPreservesSiblingOutcome() async throws {
        let appearance = AppearanceFixture(initialDarkMode: false)
        appearance.platform.readFailure = AppleScriptFailure.notAuthorized
        let recording = RecordingWritableAdapter()
        let durable = try DurableAppearanceFixture()
        let workspace = durable.workspace(instances: [
            appearance.instance,
            ConnectedTargetInstance(
                id: TargetInstanceID(rawValue: "recording.sibling"),
                displayName: "Sibling",
                adapterID: "recording"
            ),
        ])
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [appearance.adapter, recording],
            persistence: durable.store
        )

        let preview = try await engine.prepare(themeVariantID: "test-pack/dark", workspace: workspace)
        #expect(preview.userActions.contains { $0.detail.contains("Automation access") })
        let report = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        let outcomes = Dictionary(uniqueKeysWithValues: report.outcomes.map { ($0.targetInstanceID, $0) })

        #expect(outcomes[appearance.instance.id]?.configurationState == .permissionRequired)
        #expect(outcomes[appearance.instance.id]?.detail?.contains("revoked") == true)
        #expect(outcomes[TargetInstanceID(rawValue: "recording.sibling")]?.configurationState == .updated)
    }

    @Test("System Events unavailability and execution failure have distinct Capability Outcomes")
    func targetFailuresAreDistinctOutcomes() async throws {
        let unavailable = try await appearanceOutcome(for: .targetUnavailable)
        let failed = try await appearanceOutcome(
            for: .executionFailed(code: -1, message: "boom")
        )

        #expect(unavailable.preview.setupNeeds.isEmpty)
        #expect(unavailable.outcome.configurationState == .unavailable)
        #expect(unavailable.outcome.detail?.contains("unavailable") == true)
        #expect(failed.outcome.configurationState == .failed)
        #expect(failed.outcome.detail?.contains("boom") == true)
    }

    private func appearanceOutcome(
        for failure: AppleScriptFailure
    ) async throws -> (preview: ThemePreview, outcome: TargetCapabilityOutcome) {
        let fixture = AppearanceFixture(initialDarkMode: false)
        fixture.platform.readFailure = failure
        let durable = try DurableAppearanceFixture()
        let workspace = durable.workspace(instances: [fixture.instance])
        let engine = ThemeEngine(
            packs: [Fixtures.pack],
            adapters: [fixture.adapter],
            persistence: durable.store
        )
        let preview = try await engine.prepare(
            themeVariantID: "test-pack/dark",
            workspace: workspace
        )
        let report = try await engine.applyDurable(previewID: preview.id, workspace: workspace)
        return (preview, report.outcomes[0])
    }

    @Test("Undo restores the pre-apply appearance only while the intended state is owned")
    func rollbackIsGuarded() async throws {
        let fixture = AppearanceFixture(initialDarkMode: false)
        let plan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.preparedTheme(appearance: .dark)
        )
        let receipt = try await fixture.adapter.apply(plan)

        try await fixture.adapter.rollbackApply(plan: plan, receipt: receipt)
        #expect(fixture.platform.currentSnapshot == AppearanceSnapshot(darkMode: false))

        let secondPlan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.preparedTheme(appearance: .dark)
        )
        let secondReceipt = try await fixture.adapter.apply(secondPlan)
        fixture.platform.replaceCurrent(darkMode: false)
        await #expect(throws: MacOSAppearanceAdapterError.restorationConflict) {
            try await fixture.adapter.rollbackApply(plan: secondPlan, receipt: secondReceipt)
        }
    }
}

private struct DurableAppearanceFixture {
    let directory: URL
    let store: PersistenceStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("appearance-durable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try PersistenceStore(
            databaseURL: directory.appendingPathComponent("state.sqlite"),
            contentStoreURL: directory.appendingPathComponent("recovery", isDirectory: true)
        )
    }

    func workspace(instances: [ConnectedTargetInstance]) -> Workspace {
        Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: instances
        )
    }
}

private struct AppearanceFixture {
    let platform: RecordingAppearancePlatform
    let adapter: MacOSAppearanceAdapter
    let instance = ConnectedTargetInstance(
        id: MacOSAppearanceAdapter.systemTargetInstanceID,
        displayName: "System Appearance",
        adapterID: "macos.appearance"
    )

    init(initialDarkMode: Bool) {
        platform = RecordingAppearancePlatform(initialDarkMode: initialDarkMode)
        adapter = MacOSAppearanceAdapter(platform: platform)
    }

    func preparedTheme(appearance: ThemeAppearance) -> PreparedTheme {
        let variant = ThemeVariant(
            id: appearance.rawValue,
            displayName: appearance.rawValue,
            appearance: appearance,
            contentDigest: "digest-\(appearance.rawValue)",
            roles: [:]
        )
        return PreparedTheme(
            variantID: variant.id,
            variant: variant,
            sourceType: .generated,
            sourceRevision: "test",
            attribution: "Test",
            themeSchemaVersion: 1,
            contentDigest: variant.contentDigest,
            compilerVersion: "test",
            upstreamArtifact: nil
        )
    }
}

private final class RecordingAppearancePlatform: MacOSAppearancePlatform, @unchecked Sendable {
    private let lock = NSLock()
    private var darkMode: Bool
    private var _readCount = 0
    private var _applyCalls: [Bool] = []
    private var _readFailure: AppleScriptFailure?
    private var _applyResultOverride: AppearanceApplyResult?

    init(initialDarkMode: Bool) {
        darkMode = initialDarkMode
    }

    var readCount: Int {
        lock.withLock { _readCount }
    }

    var applyCalls: [Bool] {
        lock.withLock { _applyCalls }
    }

    var currentSnapshot: AppearanceSnapshot {
        lock.withLock { AppearanceSnapshot(darkMode: darkMode) }
    }

    var readFailure: AppleScriptFailure? {
        get { lock.withLock { _readFailure } }
        set { lock.withLock { _readFailure = newValue } }
    }

    var applyResultOverride: AppearanceApplyResult? {
        get { lock.withLock { _applyResultOverride } }
        set { lock.withLock { _applyResultOverride = newValue } }
    }

    func replaceCurrent(darkMode: Bool) {
        lock.withLock { self.darkMode = darkMode }
    }

    func read() throws -> AppearanceSnapshot {
        try lock.withLock {
            _readCount += 1
            if let readFailure = _readFailure {
                throw readFailure
            }
            return AppearanceSnapshot(darkMode: darkMode)
        }
    }

    func apply(darkMode desired: Bool) throws -> AppearanceApplyResult {
        lock.withLock {
            let previous = AppearanceSnapshot(darkMode: darkMode)
            guard darkMode != desired else {
                return .unchanged(current: previous)
            }
            _applyCalls.append(desired)
            if let override = _applyResultOverride {
                _applyResultOverride = nil
                return override
            }
            darkMode = desired
            return .applied(previous: previous, current: AppearanceSnapshot(darkMode: desired))
        }
    }

    func restore(_ snapshot: AppearanceSnapshot) throws -> AppearanceApplyResult {
        try apply(darkMode: snapshot.darkMode)
    }
}
