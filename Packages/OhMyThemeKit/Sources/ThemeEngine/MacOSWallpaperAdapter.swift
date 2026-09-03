import CryptoKit
import Foundation
import Persistence
import PlatformClients
import ThemeModel

// MARK: - Discovery

/// The connected-display view surfaced by ``MacOSWallpaperAdapter/discover()``.
///
/// Each entry is a currently attached display the user can choose to include in a
/// wallpaper Theme Assignment. Omitting a display is the "Keep My Current Wallpaper"
/// path for that display; nothing else changes for the display or other Capabilities.
public struct MacOSWallpaperDiscoveryReport: Codable, Equatable, Sendable {
    public let displays: [MacOSWallpaperConnectedDisplay]

    public init(displays: [MacOSWallpaperConnectedDisplay]) {
        self.displays = displays
    }
}

/// One connected display the user can turn into a Target Instance.
public struct MacOSWallpaperConnectedDisplay: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let currentImageURL: URL?
    public let currentPlacement: WallpaperPlacement?

    public init(displayID: UInt32, currentImageURL: URL?, currentPlacement: WallpaperPlacement?) {
        self.displayID = displayID
        self.currentImageURL = currentImageURL
        self.currentPlacement = currentPlacement
    }

    /// The canonical ``TargetInstanceID`` for this display.
    public var targetInstanceID: TargetInstanceID {
        MacOSWallpaperAdapter.targetInstanceID(forDisplayID: displayID)
    }
}

// MARK: - Errors

public enum MacOSWallpaperAdapterError: Error, Equatable, Sendable {
    case unsupportedInstance(TargetInstanceID)
    case unknownDisplay(UInt32)
    case wallpaperCapabilityUnavailable
    case bundledAssetMissing(String)
    case bundledAssetDigestMismatch(expected: String, observed: String)
    case malformedPlan
    case staleState
    case restorationConflict(UInt32)
    case platformFailure(String)
}

// MARK: - Payloads

/// Serialized details describing the display Target Instance the plan operates on.
public struct MacOSWallpaperConnectionDetails: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let baselineImageURL: URL
    public let baselinePlacement: WallpaperPlacement

    public init(
        displayID: UInt32,
        baselineImageURL: URL,
        baselinePlacement: WallpaperPlacement
    ) {
        self.displayID = displayID
        self.baselineImageURL = baselineImageURL
        self.baselinePlacement = baselinePlacement
    }
}

/// The apply payload carried inside a durable ``AdapterPlan``.
public struct MacOSWallpaperApplyPayload: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let intendedImageURL: URL
    public let intendedImageDigest: String
    public let baselineImageURL: URL
    public let baselinePlacement: WallpaperPlacement
    public let intendedPlacement: WallpaperPlacement

    public init(
        displayID: UInt32,
        intendedImageURL: URL,
        intendedImageDigest: String,
        baselineImageURL: URL,
        baselinePlacement: WallpaperPlacement,
        intendedPlacement: WallpaperPlacement
    ) {
        self.displayID = displayID
        self.intendedImageURL = intendedImageURL
        self.intendedImageDigest = intendedImageDigest
        self.baselineImageURL = baselineImageURL
        self.baselinePlacement = baselinePlacement
        self.intendedPlacement = intendedPlacement
    }
}

/// The disconnect payload carried inside a ``DisconnectPlan``.
///
/// Only meaningful details are carried — the baseline itself lives in the
/// engine's durable ``StoredConnectionBaseline`` referenced by the plan.
public struct MacOSWallpaperDisconnectPayload: Codable, Equatable, Sendable {
    public let displayID: UInt32

    public init(displayID: UInt32) {
        self.displayID = displayID
    }
}

// MARK: - Asset resolver

/// Resolves a Theme Variant's bundled wallpaper asset to a concrete on-disk URL.
///
/// Preparation reads the asset only to verify its content digest; it never
/// downloads, copies, or mutates the file.
public protocol MacOSWallpaperAssetResolving: Sendable {
    func resolvedAssetURL(for wallpaper: ThemeWallpaper) throws -> URL
}

/// Resolves wallpaper assets relative to a base directory (typically the containing
/// Theme Pack root).
public struct BundledWallpaperAssetResolver: MacOSWallpaperAssetResolving {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public func resolvedAssetURL(for wallpaper: ThemeWallpaper) throws -> URL {
        baseURL.appendingPathComponent(wallpaper.assetPath)
    }
}

// MARK: - Adapter

public actor MacOSWallpaperAdapter: RecoverableApplyAdapter {
    public let id = "macos.wallpaper"
    public let version = "1.0.0"
    public let payloadVersion = "1"
    public static let capabilityID = "wallpaper"

    /// Encodes a display ID as the canonical Target Instance ID for this adapter.
    public static func targetInstanceID(forDisplayID displayID: UInt32) -> TargetInstanceID {
        TargetInstanceID(rawValue: "macos.wallpaper:display:\(displayID)")
    }

    private let platform: any WallpaperPlatform
    private let assetResolver: any MacOSWallpaperAssetResolving
    private let fileManager: FileManager

    public init(
        platform: any WallpaperPlatform = SystemWallpaperPlatform(),
        assetResolver: any MacOSWallpaperAssetResolving,
        fileManager: FileManager = .default
    ) {
        self.platform = platform
        self.assetResolver = assetResolver
        self.fileManager = fileManager
    }

    // MARK: - Discovery

    public func discover() throws -> MacOSWallpaperDiscoveryReport {
        let displays = platform.connectedDisplays()
        let entries = displays.map { display -> MacOSWallpaperConnectedDisplay in
            let snapshot = try? platform.snapshot(for: display)
            return MacOSWallpaperConnectedDisplay(
                displayID: display.id,
                currentImageURL: snapshot?.imageURL,
                currentPlacement: snapshot?.placement
            )
        }
        return MacOSWallpaperDiscoveryReport(displays: entries)
    }

    // MARK: - Connection

    public func prepareConnection(
        instance: ConnectedTargetInstance,
        approveLinkedSource: Bool = false
    ) async throws -> ConnectionPlan {
        _ = approveLinkedSource  // wallpaper has no linked-source concept
        let displayID = try Self.decodedDisplayID(from: instance)
        let display = try requireConnectedDisplay(displayID)
        let snapshot = try snapshotOrThrow(for: display)

        let details = MacOSWallpaperConnectionDetails(
            displayID: displayID,
            baselineImageURL: snapshot.imageURL,
            baselinePlacement: snapshot.placement
        )
        let baselineData = try encode(snapshot)
        let opaquePayload = try encode(details)
        let digest = digest(of: opaquePayload)

        return ConnectionPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            capturedPreChangeState: baselineData,
            intendedChangeDigest: digest,
            staleStateToken: digest,
            expectedSideEffects: [
                "Records the current wallpaper for display \(displayID) so it can be restored."
            ],
            requiredPermissions: [],
            userActions: [],
            opaquePayload: opaquePayload,
            requiresApproval: false
        )
    }

    public func connect(_ plan: ConnectionPlan) async throws -> ConnectionReceipt {
        try await revalidateConnection(plan: plan)
        return ConnectionReceipt(
            configurationState: .unchanged,
            runningInstanceReach: .currentInstances,
            detail: "Recorded prior wallpaper for restoration; no display change was made."
        )
    }

    public func revalidateConnection(plan: ConnectionPlan) async throws {
        guard plan.adapterID == id else { throw MacOSWallpaperAdapterError.malformedPlan }
        let details: MacOSWallpaperConnectionDetails = try decodePayload(plan.opaquePayload)
        let display = try requireConnectedDisplay(details.displayID)
        let current = try snapshotOrThrow(for: display)
        guard current.imageURL == details.baselineImageURL,
            current.placement == details.baselinePlacement
        else {
            throw WriteBoundaryConflict(
                targetInstanceID: plan.targetInstanceID,
                detail: "Display \(details.displayID) wallpaper changed since the plan was prepared."
            )
        }
    }

    public func classifyConnection(plan: ConnectionPlan) async throws -> ReconciliationClassification {
        guard plan.adapterID == id else { throw MacOSWallpaperAdapterError.malformedPlan }
        let details: MacOSWallpaperConnectionDetails = try decodePayload(plan.opaquePayload)
        do {
            let display = try requireConnectedDisplay(details.displayID)
            let current = try snapshotOrThrow(for: display)
            if current.imageURL == details.baselineImageURL,
                current.placement == details.baselinePlacement
            {
                return .beforeChange
            }
            return .conflicting
        } catch {
            return .conflicting
        }
    }

    public func restoreConnection(instance: ConnectedTargetInstance, baseline: Data) async throws -> ConnectionReceipt {
        let baselineSnapshot: WallpaperSnapshot = try decodeBaseline(baseline)
        let displayID = baselineSnapshot.display.id
        let display = try requireConnectedDisplay(displayID)
        let current = try snapshotOrThrow(for: display)
        // Only restore when we can prove the current state is safe to overwrite:
        // either the baseline is still in place, or nothing has changed since the
        // last time we mutated. Anything else is an external edit; refuse.
        guard current.imageURL == baselineSnapshot.imageURL,
            current.placement == baselineSnapshot.placement
        else {
            throw MacOSWallpaperAdapterError.restorationConflict(displayID)
        }
        // No-op: the baseline already matches the current state.
        return ConnectionReceipt(
            configurationState: .unchanged,
            runningInstanceReach: .currentInstances,
            detail: "Display \(displayID) already matches its recorded baseline."
        )
    }

    // MARK: - Disconnect

    /// Preparing a disconnect refuses unless the display already matches its
    /// recorded baseline. This forces the caller to run Undo (or otherwise
    /// restore the wallpaper) first, so disconnect can never silently overwrite
    /// a change we don't own.
    public func prepareDisconnect(
        instance: ConnectedTargetInstance,
        baseline: StoredConnectionBaseline,
        baselineData: Data
    ) async throws -> DisconnectPlan {
        let displayID = try Self.decodedDisplayID(from: instance)
        let baselineSnapshot: WallpaperSnapshot = try decodeBaseline(baselineData)
        guard baselineSnapshot.display.id == displayID else {
            throw MacOSWallpaperAdapterError.malformedPlan
        }
        let display = try requireConnectedDisplay(displayID)
        let current = try snapshotOrThrow(for: display)
        guard current.imageURL == baselineSnapshot.imageURL,
            current.placement == baselineSnapshot.placement
        else {
            throw MacOSWallpaperAdapterError.restorationConflict(displayID)
        }
        let payload = MacOSWallpaperDisconnectPayload(displayID: displayID)
        let opaquePayload = try encode(payload)
        return DisconnectPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            baselineReference: baseline.baselineReference,
            staleStateToken: digest(of: try encode(current)),
            opaquePayload: opaquePayload
        )
    }

    /// Disconnect is a receipt-only ack: `prepareDisconnect` already proved the
    /// display sits on its baseline, and `revalidateDisconnect` re-checks that
    /// nothing drifted since. There is no additional write to make.
    public func disconnect(_ plan: DisconnectPlan, baseline: Data) async throws -> AdapterReceipt {
        try await revalidateDisconnect(plan: plan)
        let payload: MacOSWallpaperDisconnectPayload = try decodePayload(plan.opaquePayload)
        return AdapterReceipt(
            configurationState: .unchanged,
            runningInstanceReach: .currentInstances,
            detail: "Display \(payload.displayID) already matches its recorded baseline; disconnect is a no-op."
        )
    }

    public func revalidateDisconnect(plan: DisconnectPlan) async throws {
        guard plan.adapterID == id else { throw MacOSWallpaperAdapterError.malformedPlan }
        guard let opaque = plan.opaquePayload else { throw MacOSWallpaperAdapterError.malformedPlan }
        let payload: MacOSWallpaperDisconnectPayload = try decodePayload(opaque)
        let display = try requireConnectedDisplay(payload.displayID)
        let current = try snapshotOrThrow(for: display)
        // The stale-state token was computed over the exact snapshot at
        // `prepareDisconnect` time; if it doesn't still match, something
        // changed the wallpaper between prepare and disconnect and we refuse.
        let currentToken = digest(of: try encode(current))
        guard plan.staleStateToken == currentToken else {
            throw WriteBoundaryConflict(
                targetInstanceID: plan.targetInstanceID,
                detail: "Display \(payload.displayID) wallpaper changed since disconnect was prepared."
            )
        }
    }

    public func classifyDisconnect(plan: DisconnectPlan) async throws -> ReconciliationClassification {
        guard plan.adapterID == id else { throw MacOSWallpaperAdapterError.malformedPlan }
        guard let opaque = plan.opaquePayload else { throw MacOSWallpaperAdapterError.malformedPlan }
        let payload: MacOSWallpaperDisconnectPayload = try decodePayload(opaque)
        do {
            let display = try requireConnectedDisplay(payload.displayID)
            let current = try snapshotOrThrow(for: display)
            let currentToken = digest(of: try encode(current))
            if plan.staleStateToken == currentToken {
                // Nothing changed since disconnect was prepared — the display
                // still sits on the baseline. Since disconnect is a no-op, that
                // is the "after change" state we want to reach.
                return .intendedAfterChange
            }
            return .conflicting
        } catch {
            return .conflicting
        }
    }

    // MARK: - Apply

    public func prepareApply(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme
    ) async throws -> AdapterPlan {
        try await prepareApply(instance: instance, theme: theme, connectionBaseline: nil)
    }

    public func prepareApply(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme,
        connectionBaseline: Data?
    ) async throws -> AdapterPlan {
        // `connectionBaseline` is accepted for protocol conformance but is not
        // used here: the correct rollback target for a specific apply is the
        // state we're about to overwrite, not the state at connect time.
        _ = connectionBaseline
        let displayID = try Self.decodedDisplayID(from: instance)
        guard let wallpaper = theme.variant.wallpaper else {
            throw MacOSWallpaperAdapterError.wallpaperCapabilityUnavailable
        }
        let assetURL = try assetResolver.resolvedAssetURL(for: wallpaper)
        try validateBundledAsset(at: assetURL, expectedDigest: wallpaper.contentDigest)

        let display = try requireConnectedDisplay(displayID)
        let currentSnapshot = try snapshotOrThrow(for: display)

        // Rollback target is always the pre-apply state so Undo reverses this
        // specific apply. Placement is preserved ("Keep My Current") — changing
        // only the image is the whole point of the wallpaper capability.
        let intendedPlacement = currentSnapshot.placement

        let applyPayload = MacOSWallpaperApplyPayload(
            displayID: displayID,
            intendedImageURL: assetURL,
            intendedImageDigest: wallpaper.contentDigest,
            baselineImageURL: currentSnapshot.imageURL,
            baselinePlacement: currentSnapshot.placement,
            intendedPlacement: intendedPlacement
        )
        let payloadBytes = try encode(applyPayload)
        let envelope = AdapterPayloadEnvelope(
            adapterID: id,
            adapterVersion: version,
            payloadVersion: payloadVersion,
            payload: payloadBytes
        )
        let capturedPreChange = try encode(currentSnapshot)
        let intendedDigest = digest(of: payloadBytes)
        let staleToken = digest(of: capturedPreChange)

        return AdapterPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            capabilityID: Self.capabilityID,
            payload: envelope,
            intendedChangeDigest: intendedDigest,
            capturedPreChangeState: capturedPreChange,
            staleStateToken: staleToken,
            expectedSideEffects: [
                "Sets display \(displayID) wallpaper to the bundled asset while preserving its current placement."
            ],
            requiredPermissions: [],
            sourceType: theme.sourceType,
            sourceRevision: theme.sourceRevision,
            activationReach: .currentInstances,
            setupNeeds: [],
            conflicts: []
        )
    }

    public func apply(_ plan: AdapterPlan) async throws -> AdapterReceipt {
        try await revalidateApply(plan: plan)
        let payload: MacOSWallpaperApplyPayload = try decodePayload(plan.payload.payload)
        let display = try requireConnectedDisplay(payload.displayID)
        let priorSnapshot = try snapshotOrThrow(for: display)

        // Idempotent no-op when the intended state is already in place.
        if priorSnapshot.imageURL == payload.intendedImageURL,
            priorSnapshot.placement == payload.intendedPlacement
        {
            let receiptPayload = MacOSWallpaperApplyPayload(
                displayID: payload.displayID,
                intendedImageURL: payload.intendedImageURL,
                intendedImageDigest: payload.intendedImageDigest,
                baselineImageURL: payload.baselineImageURL,
                baselinePlacement: payload.baselinePlacement,
                intendedPlacement: payload.intendedPlacement
            )
            let rollback = try encode(receiptPayload)
            return AdapterReceipt(
                configurationState: .unchanged,
                runningInstanceReach: .currentInstances,
                detail: "Display \(payload.displayID) wallpaper was already the intended asset.",
                rollbackData: rollback
            )
        }

        do {
            try platform.setImage(
                payload.intendedImageURL,
                placement: payload.intendedPlacement,
                for: display
            )
        } catch {
            throw MacOSWallpaperAdapterError.platformFailure(String(describing: error))
        }

        let rollback = try encode(payload)
        return AdapterReceipt(
            configurationState: .updated,
            runningInstanceReach: .currentInstances,
            detail: "Set display \(payload.displayID) wallpaper to the bundled asset.",
            rollbackData: rollback
        )
    }

    public func revalidateApply(plan: AdapterPlan) async throws {
        guard plan.adapterID == id else { throw MacOSWallpaperAdapterError.malformedPlan }
        let payload: MacOSWallpaperApplyPayload = try decodePayload(plan.payload.payload)
        let display = try requireConnectedDisplay(payload.displayID)
        let current = try snapshotOrThrow(for: display)
        let currentBytes = try encode(current)

        // The stale-state token guards writes: either the current state matches
        // what we captured at prepare time, or the current state already matches
        // the intended after-change state (idempotent re-apply). Anything else is
        // an external edit and we must not overwrite.
        if let token = plan.staleStateToken, digest(of: currentBytes) == token {
            return
        }
        if current.imageURL == payload.intendedImageURL,
            current.placement == payload.intendedPlacement
        {
            return
        }
        throw WriteBoundaryConflict(
            targetInstanceID: plan.targetInstanceID,
            detail: "Display \(payload.displayID) wallpaper changed since the plan was prepared."
        )
    }

    public func classifyApply(plan: AdapterPlan) async throws -> ReconciliationClassification {
        guard plan.adapterID == id else { throw MacOSWallpaperAdapterError.malformedPlan }
        let payload: MacOSWallpaperApplyPayload = try decodePayload(plan.payload.payload)
        do {
            let display = try requireConnectedDisplay(payload.displayID)
            let current = try snapshotOrThrow(for: display)
            if current.imageURL == payload.intendedImageURL,
                current.placement == payload.intendedPlacement
            {
                return .intendedAfterChange
            }
            if let capturedBytes = plan.capturedPreChangeState {
                let captured: WallpaperSnapshot = try decodeBaseline(capturedBytes)
                if current == captured {
                    return .beforeChange
                }
            }
            return .conflicting
        } catch {
            return .conflicting
        }
    }

    public func recoverApplyReceipt(plan: AdapterPlan) async throws -> AdapterReceipt {
        let classification = try await classifyApply(plan: plan)
        switch classification {
        case .intendedAfterChange:
            // The write completed even though the receipt was lost. Rebuild the
            // receipt so Undo can still safely reverse it.
            let payload: MacOSWallpaperApplyPayload = try decodePayload(plan.payload.payload)
            let rollback = try encode(payload)
            return AdapterReceipt(
                configurationState: .updated,
                runningInstanceReach: .currentInstances,
                detail: "Recovered receipt for display \(payload.displayID) wallpaper apply.",
                rollbackData: rollback
            )
        case .beforeChange:
            throw MacOSWallpaperAdapterError.staleState
        case .conflicting:
            throw MacOSWallpaperAdapterError.restorationConflict(
                (try? Self.decodedDisplayID(from: plan.targetInstanceID)) ?? 0
            )
        }
    }

    public func rollbackApply(plan: AdapterPlan, receipt: AdapterReceipt) async throws {
        guard plan.adapterID == id else { throw MacOSWallpaperAdapterError.malformedPlan }
        guard let rollbackData = receipt.rollbackData else {
            throw MacOSWallpaperAdapterError.malformedPlan
        }
        let payload: MacOSWallpaperApplyPayload = try decodePayload(rollbackData)
        let display = try requireConnectedDisplay(payload.displayID)
        let current = try snapshotOrThrow(for: display)

        // Rollback is guarded: refuse if the current wallpaper isn't the intended
        // state we set, since that means someone else changed the wallpaper after
        // apply and we don't own that state.
        guard current.imageURL == payload.intendedImageURL,
            current.placement == payload.intendedPlacement
        else {
            throw MacOSWallpaperAdapterError.restorationConflict(payload.displayID)
        }

        do {
            try platform.setImage(
                payload.baselineImageURL,
                placement: payload.baselinePlacement,
                for: display
            )
        } catch {
            throw MacOSWallpaperAdapterError.platformFailure(String(describing: error))
        }
    }

    // MARK: - Helpers

    private func requireConnectedDisplay(_ displayID: UInt32) throws -> WallpaperDisplay {
        let displays = platform.connectedDisplays()
        guard let display = displays.first(where: { $0.id == displayID }) else {
            throw MacOSWallpaperAdapterError.unknownDisplay(displayID)
        }
        return display
    }

    private func snapshotOrThrow(for display: WallpaperDisplay) throws -> WallpaperSnapshot {
        do {
            return try platform.snapshot(for: display)
        } catch let error as WallpaperCapabilityError {
            throw error
        } catch {
            throw MacOSWallpaperAdapterError.platformFailure(String(describing: error))
        }
    }

    private static func decodedDisplayID(from instance: ConnectedTargetInstance) throws -> UInt32 {
        try decodedDisplayID(from: instance.id)
    }

    private static func decodedDisplayID(from id: TargetInstanceID) throws -> UInt32 {
        let prefix = "macos.wallpaper:display:"
        guard id.rawValue.hasPrefix(prefix),
            let value = UInt32(id.rawValue.dropFirst(prefix.count))
        else {
            throw MacOSWallpaperAdapterError.unsupportedInstance(id)
        }
        return value
    }

    private func validateBundledAsset(at url: URL, expectedDigest: String) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw MacOSWallpaperAdapterError.bundledAssetMissing(url.lastPathComponent)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MacOSWallpaperAdapterError.bundledAssetMissing(url.lastPathComponent)
        }
        let observed = digest(of: data)
        guard observed == expectedDigest else {
            throw MacOSWallpaperAdapterError.bundledAssetDigestMismatch(
                expected: expectedDigest,
                observed: observed
            )
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func decodePayload<T: Decodable>(_ data: Data?) throws -> T {
        guard let data else { throw MacOSWallpaperAdapterError.malformedPlan }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MacOSWallpaperAdapterError.malformedPlan
        }
    }

    private func decodeBaseline<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MacOSWallpaperAdapterError.malformedPlan
        }
    }

    private func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
