import CryptoKit
import Foundation
import Persistence
import PlatformClients
import Testing
import ThemeModel

@testable import ThemeEngine

// MARK: - Fixtures

private struct WallpaperFixture {
    let directory: URL
    let assetURL: URL
    let assetDigest: String
    let displayID: UInt32 = 1
    let platform: FakeWallpaperPlatform
    let adapter: MacOSWallpaperAdapter
    let instance: ConnectedTargetInstance

    init(
        initialImageURL: URL? = nil,
        initialPlacement: WallpaperPlacement? = nil,
        assetBytes: Data? = nil
    ) throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wallpaper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        assetURL = directory.appendingPathComponent("aurora.jpg")
        let bytes = assetBytes ?? Data("aurora-bundle".utf8)
        try bytes.write(to: assetURL)
        assetDigest = WallpaperFixture.digest(of: bytes)

        let startImage = initialImageURL ?? URL(fileURLWithPath: "/Library/Desktop Pictures/Original.jpg")
        let startPlacement = initialPlacement ?? WallpaperPlacement(scaling: 1, allowsClipping: true)
        let start = WallpaperSnapshot(
            display: WallpaperDisplay(id: displayID),
            imageURL: startImage,
            placement: startPlacement
        )
        platform = FakeWallpaperPlatform(displays: [start.display], initial: [displayID: start])
        adapter = MacOSWallpaperAdapter(
            platform: platform,
            assetResolver: FixedAssetResolver(url: assetURL)
        )
        instance = ConnectedTargetInstance(
            id: MacOSWallpaperAdapter.targetInstanceID(forDisplayID: displayID),
            displayName: "Display \(displayID)",
            adapterID: "macos.wallpaper"
        )
    }

    func themeVariant() -> ThemeVariant {
        ThemeVariant(
            id: "aurora-dark",
            displayName: "Aurora Dark",
            appearance: .dark,
            contentDigest: "variant-digest",
            roles: [:],
            wallpaper: ThemeWallpaper(
                assetPath: "aurora.jpg",
                contentDigest: assetDigest,
                attribution: "Test fixture"
            )
        )
    }

    func preparedTheme(variant: ThemeVariant? = nil) -> PreparedTheme {
        let v = variant ?? themeVariant()
        return PreparedTheme(
            variantID: v.id,
            variant: v,
            sourceType: .generated,
            sourceRevision: "test-revision",
            attribution: "Test",
            themeSchemaVersion: 1,
            contentDigest: v.contentDigest,
            compilerVersion: "test",
            upstreamArtifact: nil
        )
    }

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class FakeWallpaperPlatform: WallpaperPlatform, @unchecked Sendable {
    struct SetCall {
        let displayID: UInt32
        let imageURL: URL
        let placement: WallpaperPlacement
    }

    private let queue = DispatchQueue(label: "FakeWallpaperPlatform")
    private var _displays: [WallpaperDisplay]
    private var _snapshots: [UInt32: WallpaperSnapshot]
    private var _setCalls: [SetCall] = []
    var failNextSet: Error?

    init(displays: [WallpaperDisplay], initial: [UInt32: WallpaperSnapshot]) {
        _displays = displays
        _snapshots = initial
    }

    var setCalls: [SetCall] {
        queue.sync { _setCalls }
    }

    func replaceSnapshot(_ snapshot: WallpaperSnapshot) {
        queue.sync { _snapshots[snapshot.display.id] = snapshot }
    }

    func removeDisplay(_ id: UInt32) {
        queue.sync {
            _displays.removeAll { $0.id == id }
            _snapshots.removeValue(forKey: id)
        }
    }

    func appendDisplay(_ display: WallpaperDisplay) {
        queue.sync {
            if !_displays.contains(where: { $0.id == display.id }) {
                _displays.append(display)
            }
        }
    }

    func connectedDisplays() -> [WallpaperDisplay] {
        queue.sync { _displays }
    }

    func snapshot(for display: WallpaperDisplay) throws -> WallpaperSnapshot {
        try queue.sync {
            guard let snap = _snapshots[display.id] else {
                throw WallpaperCapabilityError.missingCurrentImage(display.id)
            }
            return snap
        }
    }

    func setImage(_ imageURL: URL, placement: WallpaperPlacement, for display: WallpaperDisplay) throws {
        try queue.sync {
            if let error = failNextSet {
                failNextSet = nil
                throw error
            }
            _setCalls.append(SetCall(displayID: display.id, imageURL: imageURL, placement: placement))
            _snapshots[display.id] = WallpaperSnapshot(
                display: display,
                imageURL: imageURL,
                placement: placement
            )
        }
    }
}

private struct FixedAssetResolver: MacOSWallpaperAssetResolving {
    let url: URL

    func resolvedAssetURL(for wallpaper: ThemeWallpaper) throws -> URL {
        url
    }
}

// MARK: - Tests

@Suite("macOS wallpaper adapter (issue #17)")
struct MacOSWallpaperAdapterTests {
    // MARK: Discovery

    @Test("Discovery reports connected displays and current wallpaper without writing")
    func discoveryEnumeratesDisplaysWithoutWriting() async throws {
        let fixture = try WallpaperFixture()
        let report = try await fixture.adapter.discover()
        #expect(report.displays.count == 1)
        #expect(report.displays[0].displayID == fixture.displayID)
        #expect(report.displays[0].currentImageURL?.lastPathComponent == "Original.jpg")
        #expect(fixture.platform.setCalls.isEmpty)
    }

    @Test("Discovery returns an empty list when no displays are connected")
    func discoveryEmptyWhenNoDisplays() async throws {
        let fixture = try WallpaperFixture()
        fixture.platform.removeDisplay(fixture.displayID)
        let report = try await fixture.adapter.discover()
        #expect(report.displays.isEmpty)
    }

    // MARK: Connection

    @Test("Connection preparation captures the display's current wallpaper as its baseline")
    func connectionPrepCapturesBaseline() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        #expect(plan.targetInstanceID == fixture.instance.id)
        #expect(plan.adapterID == "macos.wallpaper")
        #expect(plan.opaquePayload != nil)
        // The connection plan mutates nothing.
        #expect(fixture.platform.setCalls.isEmpty)

        // Baseline round-trips a WallpaperSnapshot.
        let baseline = try JSONDecoder().decode(WallpaperSnapshot.self, from: plan.capturedPreChangeState)
        #expect(baseline.display.id == fixture.displayID)
        #expect(baseline.imageURL.lastPathComponent == "Original.jpg")
    }

    @Test("Connection preparation refuses an unsupported Target Instance ID")
    func connectionPrepRejectsUnsupportedInstance() async throws {
        let fixture = try WallpaperFixture()
        let bad = ConnectedTargetInstance(
            id: TargetInstanceID(rawValue: "starship:default"),
            displayName: "Bad",
            adapterID: "macos.wallpaper"
        )
        await #expect(throws: MacOSWallpaperAdapterError.unsupportedInstance(bad.id)) {
            _ = try await fixture.adapter.prepareConnection(instance: bad)
        }
    }

    @Test("Connection preparation refuses an unknown display")
    func connectionPrepRejectsUnknownDisplay() async throws {
        let fixture = try WallpaperFixture()
        fixture.platform.removeDisplay(fixture.displayID)
        await #expect(throws: MacOSWallpaperAdapterError.unknownDisplay(fixture.displayID)) {
            _ = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        }
    }

    @Test("Connection preparation survives Codable round-trip (restart-safe plan)")
    func connectionPlanRoundTrips() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        let bytes = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(ConnectionPlan.self, from: bytes)
        #expect(decoded == plan)
    }

    @Test("Connect records the baseline and does not change the display")
    func connectReturnsUnchangedReceipt() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        let receipt = try await fixture.adapter.connect(plan)
        #expect(receipt.configurationState == .unchanged)
        #expect(receipt.runningInstanceReach == .currentInstances)
        #expect(fixture.platform.setCalls.isEmpty)
    }

    @Test("Connect refuses when the wallpaper changed between prepare and connect")
    func connectRefusesExternalEdit() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        fixture.platform.replaceSnapshot(
            WallpaperSnapshot(
                display: WallpaperDisplay(id: fixture.displayID),
                imageURL: URL(fileURLWithPath: "/tmp/user-changed.png"),
                placement: WallpaperPlacement(scaling: 3, allowsClipping: false)
            )
        )
        await #expect(throws: WriteBoundaryConflict.self) {
            _ = try await fixture.adapter.connect(plan)
        }
    }

    @Test("Connection restore is a no-op when the baseline still matches, and refuses when it doesn't")
    func connectionRestoreRefusesExternalEdit() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        _ = try await fixture.adapter.connect(plan)

        // Baseline still matches: restore is a safe no-op.
        let baselineData = plan.capturedPreChangeState
        let receipt = try await fixture.adapter.restoreConnection(instance: fixture.instance, baseline: baselineData)
        #expect(receipt.configurationState == .unchanged)
        #expect(fixture.platform.setCalls.isEmpty)

        // Now an external edit happens: restore refuses instead of overwriting.
        fixture.platform.replaceSnapshot(
            WallpaperSnapshot(
                display: WallpaperDisplay(id: fixture.displayID),
                imageURL: URL(fileURLWithPath: "/tmp/user-changed.png"),
                placement: WallpaperPlacement(scaling: 3, allowsClipping: false)
            )
        )
        await #expect(throws: MacOSWallpaperAdapterError.restorationConflict(fixture.displayID)) {
            _ = try await fixture.adapter.restoreConnection(instance: fixture.instance, baseline: baselineData)
        }
    }

    // MARK: Apply preparation

    @Test("Apply preparation refuses a variant with no wallpaper (capability opt-out)")
    func applyPrepRefusesMissingWallpaper() async throws {
        let fixture = try WallpaperFixture()
        let variant = ThemeVariant(
            id: "no-wallpaper",
            displayName: "No wallpaper",
            appearance: .dark,
            contentDigest: "digest",
            roles: [:],
            wallpaper: nil
        )
        let theme = fixture.preparedTheme(variant: variant)
        await #expect(throws: MacOSWallpaperAdapterError.wallpaperCapabilityUnavailable) {
            _ = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: theme)
        }
    }

    @Test("Apply preparation refuses when the bundled asset is missing")
    func applyPrepRefusesMissingAsset() async throws {
        let fixture = try WallpaperFixture()
        try FileManager.default.removeItem(at: fixture.assetURL)
        let theme = fixture.preparedTheme()
        await #expect(throws: MacOSWallpaperAdapterError.self) {
            _ = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: theme)
        }
    }

    @Test("Apply preparation refuses when the bundled asset digest mismatches")
    func applyPrepRefusesDigestMismatch() async throws {
        let fixture = try WallpaperFixture()
        let badVariant = ThemeVariant(
            id: "bad-digest",
            displayName: "Bad digest",
            appearance: .dark,
            contentDigest: "digest",
            roles: [:],
            wallpaper: ThemeWallpaper(
                assetPath: "aurora.jpg",
                contentDigest: "not-the-real-digest",
                attribution: "attr"
            )
        )
        let theme = fixture.preparedTheme(variant: badVariant)
        await #expect(throws: MacOSWallpaperAdapterError.self) {
            _ = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: theme)
        }
    }

    @Test("Apply preparation reports currentInstances reach and does not write")
    func applyPrepIsPure() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: fixture.preparedTheme())
        #expect(plan.activationReach == .currentInstances)
        #expect(plan.capabilityID == "wallpaper")
        #expect(plan.adapterID == "macos.wallpaper")
        #expect(plan.setupNeeds.isEmpty)
        #expect(plan.conflicts.isEmpty)
        #expect(fixture.platform.setCalls.isEmpty)
    }

    @Test("Apply preparation preserves the display's current placement")
    func applyPrepPreservesPlacement() async throws {
        let placement = WallpaperPlacement(scaling: 3, allowsClipping: false)
        let fixture = try WallpaperFixture(initialPlacement: placement)
        let plan = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: fixture.preparedTheme())
        let payload = try JSONDecoder().decode(MacOSWallpaperApplyPayload.self, from: plan.payload.payload)
        #expect(payload.intendedPlacement == placement)
    }

    @Test("Apply preparation captures the pre-apply snapshot as the rollback baseline")
    func applyPrepUsesCurrentSnapshotForRollback() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: fixture.preparedTheme())
        let payload = try JSONDecoder().decode(MacOSWallpaperApplyPayload.self, from: plan.payload.payload)
        // The rollback target is the current wallpaper at prepare time, not any
        // stashed connection-baseline data — so Undo reverses this specific apply.
        #expect(payload.baselineImageURL.lastPathComponent == "Original.jpg")
        #expect(payload.baselinePlacement == WallpaperPlacement(scaling: 1, allowsClipping: true))
    }

    @Test("Apply preparation ignores an unrelated connection-baseline payload")
    func applyPrepIgnoresConnectionBaselineOverride() async throws {
        let fixture = try WallpaperFixture()
        let unrelatedBaseline = try JSONEncoder().encode(
            WallpaperSnapshot(
                display: WallpaperDisplay(id: fixture.displayID),
                imageURL: URL(fileURLWithPath: "/tmp/should-be-ignored.png"),
                placement: WallpaperPlacement(scaling: 99, allowsClipping: false)
            )
        )
        let plan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.preparedTheme(),
            connectionBaseline: unrelatedBaseline
        )
        let payload = try JSONDecoder().decode(MacOSWallpaperApplyPayload.self, from: plan.payload.payload)
        #expect(payload.baselineImageURL.lastPathComponent == "Original.jpg")
    }

    @Test("Apply plan survives Codable round-trip (restart-safe)")
    func applyPlanRoundTrips() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: fixture.preparedTheme())
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(AdapterPlan.self, from: data)
        #expect(decoded == plan)
    }

    // MARK: Apply

    @Test("Apply sets the bundled asset via the platform and returns an updated receipt")
    func applyDrivesPlatform() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: fixture.preparedTheme())
        let receipt = try await fixture.adapter.apply(plan)
        #expect(receipt.configurationState == .updated)
        #expect(receipt.runningInstanceReach == .currentInstances)
        #expect(receipt.rollbackData != nil)
        #expect(fixture.platform.setCalls.count == 1)
        #expect(fixture.platform.setCalls[0].imageURL == fixture.assetURL)
    }

    @Test("Apply is idempotent when the intended state is already in place")
    func applyIdempotent() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: fixture.preparedTheme())
        _ = try await fixture.adapter.apply(plan)
        let receipt = try await fixture.adapter.apply(plan)
        #expect(receipt.configurationState == .unchanged)
        #expect(fixture.platform.setCalls.count == 1)
    }

    @Test("Apply refuses when the display's wallpaper changed after prepare (external edit)")
    func applyRefusesStalePlan() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: fixture.preparedTheme())
        fixture.platform.replaceSnapshot(
            WallpaperSnapshot(
                display: WallpaperDisplay(id: fixture.displayID),
                imageURL: URL(fileURLWithPath: "/tmp/user-changed.png"),
                placement: WallpaperPlacement(scaling: 5, allowsClipping: false)
            )
        )
        await #expect(throws: WriteBoundaryConflict.self) {
            _ = try await fixture.adapter.apply(plan)
        }
        #expect(fixture.platform.setCalls.isEmpty)
    }

    @Test("Apply surfaces platform failures as MacOSWallpaperAdapterError.platformFailure")
    func applyReportsPlatformFailures() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: fixture.preparedTheme())
        fixture.platform.failNextSet = WallpaperCapabilityError.displayUnavailable(fixture.displayID)
        await #expect(throws: MacOSWallpaperAdapterError.self) {
            _ = try await fixture.adapter.apply(plan)
        }
    }

    // MARK: Recovery & classification

    @Test("Classify apply distinguishes beforeChange, intendedAfterChange, and conflicting")
    func classifyApplyBuckets() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: fixture.preparedTheme())

        // Before change: current == captured pre-change.
        #expect(try await fixture.adapter.classifyApply(plan: plan) == .beforeChange)

        // Intended after change: current == intended image + placement.
        _ = try await fixture.adapter.apply(plan)
        #expect(try await fixture.adapter.classifyApply(plan: plan) == .intendedAfterChange)

        // Conflicting: external edit lands.
        fixture.platform.replaceSnapshot(
            WallpaperSnapshot(
                display: WallpaperDisplay(id: fixture.displayID),
                imageURL: URL(fileURLWithPath: "/tmp/user-changed.png"),
                placement: WallpaperPlacement(scaling: 7)
            )
        )
        #expect(try await fixture.adapter.classifyApply(plan: plan) == .conflicting)
    }

    @Test("Recover receipt reconstructs a usable receipt when the write already landed")
    func recoverReceiptRebuildsForUndo() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: fixture.preparedTheme())
        _ = try await fixture.adapter.apply(plan)
        let receipt = try await fixture.adapter.recoverApplyReceipt(plan: plan)
        #expect(receipt.configurationState == .updated)
        #expect(receipt.rollbackData != nil)
    }

    @Test("Recover receipt refuses when nothing was applied yet (staleState)")
    func recoverReceiptRefusesBeforeChange() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: fixture.preparedTheme())
        await #expect(throws: MacOSWallpaperAdapterError.staleState) {
            _ = try await fixture.adapter.recoverApplyReceipt(plan: plan)
        }
    }

    // MARK: Rollback

    @Test("Rollback restores the baseline wallpaper when the intended state is still in place")
    func rollbackRestoresBaseline() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: fixture.preparedTheme())
        let receipt = try await fixture.adapter.apply(plan)

        try await fixture.adapter.rollbackApply(plan: plan, receipt: receipt)
        // Baseline was Original.jpg, and rollback set it back.
        #expect(fixture.platform.setCalls.count == 2)
        #expect(fixture.platform.setCalls[1].imageURL.lastPathComponent == "Original.jpg")
    }

    @Test("Rollback refuses when someone else changed the wallpaper after apply")
    func rollbackRefusesExternalEdit() async throws {
        let fixture = try WallpaperFixture()
        let plan = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: fixture.preparedTheme())
        let receipt = try await fixture.adapter.apply(plan)
        fixture.platform.replaceSnapshot(
            WallpaperSnapshot(
                display: WallpaperDisplay(id: fixture.displayID),
                imageURL: URL(fileURLWithPath: "/tmp/user-changed.png"),
                placement: WallpaperPlacement(scaling: 9)
            )
        )
        await #expect(throws: MacOSWallpaperAdapterError.restorationConflict(fixture.displayID)) {
            try await fixture.adapter.rollbackApply(plan: plan, receipt: receipt)
        }
    }

    // MARK: Disconnect

    @Test("Disconnect refuses to prepare when the display doesn't match its baseline")
    func disconnectPrepRefusesExternalEdit() async throws {
        let fixture = try WallpaperFixture()
        let connectionPlan = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        _ = try await fixture.adapter.connect(connectionPlan)
        let baselineData = connectionPlan.capturedPreChangeState

        // Simulate a stray change (a theme apply that hasn't been undone, or a
        // user-initiated wallpaper change): current wallpaper no longer matches
        // the recorded baseline.
        fixture.platform.replaceSnapshot(
            WallpaperSnapshot(
                display: WallpaperDisplay(id: fixture.displayID),
                imageURL: URL(fileURLWithPath: "/tmp/still-different.png"),
                placement: WallpaperPlacement(scaling: 7)
            )
        )

        let stored = StoredConnectionBaseline(
            targetInstanceID: fixture.instance.id,
            adapterID: "macos.wallpaper",
            adapterVersion: "1.0.0",
            baselineReference: ContentReference(digest: "d", byteCount: 0),
            capturedAt: Date()
        )
        await #expect(throws: MacOSWallpaperAdapterError.restorationConflict(fixture.displayID)) {
            _ = try await fixture.adapter.prepareDisconnect(
                instance: fixture.instance,
                baseline: stored,
                baselineData: baselineData
            )
        }
        // And no writes happened either during prepare or after.
        #expect(fixture.platform.setCalls.isEmpty)
    }

    @Test("Disconnect only succeeds after Undo returns the display to its baseline")
    func disconnectRestoresBaseline() async throws {
        let fixture = try WallpaperFixture()

        // 1. Connect
        let connectionPlan = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        _ = try await fixture.adapter.connect(connectionPlan)
        let baselineData = connectionPlan.capturedPreChangeState

        // 2. Apply
        let applyPlan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.preparedTheme(),
            connectionBaseline: baselineData
        )
        let receipt = try await fixture.adapter.apply(applyPlan)

        // 3. Undo (rollback) — required before Disconnect can succeed.
        try await fixture.adapter.rollbackApply(plan: applyPlan, receipt: receipt)

        // 4. Disconnect: safe because display is back at baseline.
        let stored = StoredConnectionBaseline(
            targetInstanceID: fixture.instance.id,
            adapterID: "macos.wallpaper",
            adapterVersion: "1.0.0",
            baselineReference: ContentReference(digest: "d", byteCount: 0),
            capturedAt: Date()
        )
        let disconnectPlan = try await fixture.adapter.prepareDisconnect(
            instance: fixture.instance,
            baseline: stored,
            baselineData: baselineData
        )
        let disconnectReceipt = try await fixture.adapter.disconnect(disconnectPlan, baseline: baselineData)
        #expect(disconnectReceipt.configurationState == .unchanged)
        // Only the apply and the rollback set the wallpaper; disconnect makes no writes.
        #expect(fixture.platform.setCalls.count == 2)
    }

    @Test("Disconnect is a no-op when the display already matches the baseline")
    func disconnectNoopWhenMatches() async throws {
        let fixture = try WallpaperFixture()
        let connectionPlan = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        _ = try await fixture.adapter.connect(connectionPlan)
        let stored = StoredConnectionBaseline(
            targetInstanceID: fixture.instance.id,
            adapterID: "macos.wallpaper",
            adapterVersion: "1.0.0",
            baselineReference: ContentReference(digest: "d", byteCount: 0),
            capturedAt: Date()
        )
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
    }

    // MARK: Public API limits

    @Test("Non-selected displays are never touched during an apply (Keep My Current Wallpaper)")
    func nonSelectedDisplayUntouched() async throws {
        // Two displays connected; only display 1 becomes a Target Instance.
        let firstImage = URL(fileURLWithPath: "/Library/Desktop Pictures/One.jpg")
        let secondImage = URL(fileURLWithPath: "/Library/Desktop Pictures/Two.jpg")
        let firstPlacement = WallpaperPlacement(scaling: 1, allowsClipping: true)
        let secondPlacement = WallpaperPlacement(scaling: 4, allowsClipping: false)
        let fixture = try WallpaperFixture(
            initialImageURL: firstImage,
            initialPlacement: firstPlacement
        )
        // Add a second display the adapter can see but the caller does not select.
        fixture.platform.replaceSnapshot(
            WallpaperSnapshot(
                display: WallpaperDisplay(id: 2),
                imageURL: secondImage,
                placement: secondPlacement
            )
        )
        fixture.platform.appendDisplay(WallpaperDisplay(id: 2))

        let plan = try await fixture.adapter.prepareApply(instance: fixture.instance, theme: fixture.preparedTheme())
        _ = try await fixture.adapter.apply(plan)

        // Every setImage call must be scoped to display 1.
        #expect(fixture.platform.setCalls.allSatisfy { $0.displayID == fixture.displayID })
        // Display 2's snapshot must be unchanged.
        let second = try fixture.platform.snapshot(for: WallpaperDisplay(id: 2))
        #expect(second.imageURL == secondImage)
        #expect(second.placement == secondPlacement)
    }

    @Test("The adapter never invokes any private preference writes or GUI automation")
    func adapterUsesOnlyPublicPlatformSeams() async throws {
        // The adapter can only reach into macOS through the WallpaperPlatform protocol,
        // whose production implementation is `SystemWallpaperPlatform` (NSWorkspace).
        // Verify the adapter has no other side-effect surface by driving a full lifecycle
        // and asserting only `setImage` calls landed on the platform seam.
        let fixture = try WallpaperFixture()
        let connectionPlan = try await fixture.adapter.prepareConnection(instance: fixture.instance)
        _ = try await fixture.adapter.connect(connectionPlan)
        let applyPlan = try await fixture.adapter.prepareApply(
            instance: fixture.instance,
            theme: fixture.preparedTheme(),
            connectionBaseline: connectionPlan.capturedPreChangeState
        )
        let receipt = try await fixture.adapter.apply(applyPlan)
        try await fixture.adapter.rollbackApply(plan: applyPlan, receipt: receipt)
        #expect(fixture.platform.setCalls.count == 2)
    }
}
