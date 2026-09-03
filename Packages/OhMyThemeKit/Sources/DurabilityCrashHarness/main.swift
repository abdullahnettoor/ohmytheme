import Foundation
import Persistence
import ThemeEngine
import ThemeModel

@main
struct DurabilityCrashHarness {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count >= 3,
                let command = Command(rawValue: arguments[0]),
                let scenario = Scenario(rawValue: arguments[1])
            else {
                throw HarnessError.invalidArguments
            }

            let rootURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
            switch command {
            case .discover:
                let recorder = CheckpointRecorder(mode: .discover)
                try await run(scenario: scenario, rootURL: rootURL, recorder: recorder)
                try writeJSON(Discovery(checkpoints: recorder.checkpoints))
            case .run:
                guard arguments.count == 4, let ordinal = Int(arguments[3]) else {
                    throw HarnessError.invalidArguments
                }
                let recorder = CheckpointRecorder(
                    mode: .stop(ordinal: ordinal, markerURL: paths(rootURL).marker)
                )
                try await run(scenario: scenario, rootURL: rootURL, recorder: recorder)
                throw HarnessError.checkpointNotReached(ordinal)
            case .verify:
                let verification = try await verify(scenario: scenario, rootURL: rootURL)
                try writeJSON(verification)
            }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            Foundation.exit(2)
        }
    }

    private static func run(
        scenario: Scenario,
        rootURL: URL,
        recorder: CheckpointRecorder
    ) async throws {
        try resetFixture(at: rootURL)
        try await prepareFixture(for: scenario, rootURL: rootURL)

        let locations = paths(rootURL)
        let store = try PersistenceStore(
            databaseURL: locations.database,
            contentStoreURL: locations.content,
            checkpointHandler: recorder.record
        )
        let adapter = FileBackedAdapter(stateURL: locations.externalState)
        let engine = ThemeEngine(
            packs: [fixturePack],
            adapters: [adapter],
            persistence: store
        )
        try await perform(scenario, engine: engine)
    }

    private static func prepareFixture(for scenario: Scenario, rootURL: URL) async throws {
        let locations = paths(rootURL)
        try FileBackedAdapter.initializeState(at: locations.externalState)
        let store = try PersistenceStore(
            databaseURL: locations.database,
            contentStoreURL: locations.content
        )
        try store.saveWorkspace(
            disconnectedWorkspace,
            targetInstances: [
                PersistedTargetInstance(
                    id: instance.id,
                    displayName: instance.displayName,
                    adapterID: instance.adapterID,
                    isConnected: false
                )
            ]
        )

        guard scenario != .connect else { return }
        let adapter = FileBackedAdapter(stateURL: locations.externalState)
        let engine = ThemeEngine(
            packs: [fixturePack],
            adapters: [adapter],
            persistence: store
        )
        _ = try await engine.connect(instance: instance, workspace: disconnectedWorkspace)

        guard scenario != .apply else { return }
        let preview = try await engine.prepare(workspace: connectedWorkspace)
        _ = try await engine.applyDurable(previewID: preview.id, workspace: connectedWorkspace)
    }

    private static func perform(_ scenario: Scenario, engine: ThemeEngine) async throws {
        switch scenario {
        case .connect:
            _ = try await engine.connect(instance: instance, workspace: disconnectedWorkspace)
        case .apply:
            let preview = try await engine.prepare(workspace: connectedWorkspace)
            _ = try await engine.applyDurable(previewID: preview.id, workspace: connectedWorkspace)
        case .undo:
            _ = try await engine.undoLast(workspace: connectedWorkspace)
        case .restore:
            _ = try await engine.restore(instance: instance, workspace: connectedWorkspace)
        case .disconnect:
            _ = try await engine.disconnect(instance: instance, workspace: connectedWorkspace)
        }
    }

    private static func verify(scenario: Scenario, rootURL: URL) async throws -> Verification {
        let locations = paths(rootURL)
        let store = try PersistenceStore(
            databaseURL: locations.database,
            contentStoreURL: locations.content
        )
        let adapter = FileBackedAdapter(stateURL: locations.externalState)
        let engine = ThemeEngine(
            packs: [fixturePack],
            adapters: [adapter],
            persistence: store
        )
        let interruptedBefore = try store.journalInterruptedOperations()
        var failures: [String] = []

        do {
            try await engine.reconcileInterruptedOperations()
        } catch {
            failures.append("reconciliation failed: \(error)")
        }

        let state = try FileBackedAdapter.loadState(at: locations.externalState)
        let persisted = try store.loadWorkspace()
        let member = persisted.targetInstances.first { $0.id == instance.id }
        let baseline = try store.journalLoadConnectionBaseline(targetInstanceID: instance.id)
        let baselineBytes = try baseline.map { try store.loadContent($0.baselineReference) }

        if state.configuration != userOwnedConfiguration,
            state.configuration != themeConfiguration
        {
            failures.append("external configuration is neither the exact user bytes nor the intended theme bytes")
        }
        if state.configuration != userOwnedConfiguration,
            baselineBytes != userOwnedConfiguration
        {
            failures.append("user-owned configuration is absent from both the target and its connection baseline")
        }
        if member?.isConnected != state.connected {
            failures.append("persisted membership disagrees with the file-backed target")
        }
        if state.connected {
            if baselineBytes != userOwnedConfiguration {
                failures.append("connected target does not retain its exact connection baseline")
            }
        } else if baseline != nil {
            failures.append("disconnected target retains a connection baseline")
        }

        let interruptedAfter = try store.journalInterruptedOperations()
        if !interruptedAfter.isEmpty {
            failures.append("reconciliation left interrupted operations")
        }

        for operation in interruptedBefore {
            guard let reloaded = try store.journalLoadOperation(id: operation.id) else {
                failures.append("interrupted operation disappeared")
                continue
            }
            if reloaded.state != .reconciled {
                failures.append("interrupted operation did not become reconciled")
            }
            let records = try store.journalLoadRecords(operationID: operation.id)
            if records.contains(where: { $0.phase == .prepared || $0.phase == .applying }) {
                failures.append("reconciled operation retains a nonterminal record")
            }
            for digest in records.compactMap(\.planDigest) {
                do {
                    _ = try store.journalLoadContent(digest: digest)
                } catch {
                    failures.append("journal plan content is missing")
                }
            }
        }

        try verifyOperationSpecificState(
            scenario: scenario,
            state: state,
            store: store,
            failures: &failures
        )
        return Verification(failures: failures)
    }

    private static func verifyOperationSpecificState(
        scenario: Scenario,
        state: SyntheticState,
        store: PersistenceStore,
        failures: inout [String]
    ) throws {
        switch scenario {
        case .connect:
            if state.configuration != userOwnedConfiguration {
                failures.append("connect changed user-owned configuration bytes")
            }
        case .apply:
            let lastApply = try store.journalFindLastAppliedTransaction(workspaceID: .myMac)
            if (state.configuration == themeConfiguration) != (lastApply != nil) {
                failures.append("apply journal does not describe the external configuration")
            }
        case .undo:
            let lastApply = try store.journalFindLastAppliedTransaction(workspaceID: .myMac)
            if state.configuration == themeConfiguration, lastApply == nil {
                failures.append("undo retired an apply receipt without rolling it back")
            }
            if state.configuration == userOwnedConfiguration, lastApply != nil {
                failures.append("undo restored bytes without retiring the source apply receipt")
            }
        case .restore:
            if !state.connected {
                failures.append("restore changed Workspace membership")
            }
        case .disconnect:
            if !state.connected, state.configuration != userOwnedConfiguration {
                failures.append("disconnect removed membership without restoring exact user bytes")
            }
        }
    }

    private static func resetFixture(at rootURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.removeItem(at: rootURL)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private static func paths(_ rootURL: URL) -> FixturePaths {
        FixturePaths(
            database: rootURL.appendingPathComponent("state.sqlite"),
            content: rootURL.appendingPathComponent("content", isDirectory: true),
            externalState: rootURL.appendingPathComponent("synthetic-target.json"),
            marker: rootURL.appendingPathComponent("checkpoint-marker.json")
        )
    }

    private static func writeJSON<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private enum Command: String {
    case discover
    case run
    case verify
}

private enum Scenario: String {
    case connect
    case apply
    case undo
    case restore
    case disconnect
}

private struct FixturePaths {
    let database: URL
    let content: URL
    let externalState: URL
    let marker: URL
}

private struct Discovery: Encodable {
    let checkpoints: [String]
}

private struct Verification: Encodable {
    let failures: [String]
}

private struct CheckpointMarker: Encodable {
    let ordinal: Int
    let checkpoint: String
}

private final class CheckpointRecorder: @unchecked Sendable {
    enum Mode {
        case discover
        case stop(ordinal: Int, markerURL: URL)
    }

    private let mode: Mode
    private let lock = NSLock()
    private var recorded: [String] = []

    init(mode: Mode) {
        self.mode = mode
    }

    var checkpoints: [String] {
        lock.withLock { recorded }
    }

    func record(_ checkpoint: DurableJournalCheckpoint) {
        let ordinal = lock.withLock { () -> Int in
            let ordinal = recorded.count
            recorded.append(checkpoint.rawValue)
            return ordinal
        }
        guard case .stop(let targetOrdinal, let markerURL) = mode,
            ordinal == targetOrdinal
        else {
            return
        }

        let marker = CheckpointMarker(ordinal: ordinal, checkpoint: checkpoint.rawValue)
        if let data = try? JSONEncoder().encode(marker) {
            try? data.write(to: markerURL, options: .atomic)
        }
        while true {
            Thread.sleep(forTimeInterval: 60)
        }
    }
}

private struct SyntheticState: Codable {
    let configuration: Data
    let connected: Bool
}

private actor FileBackedAdapter: RecoverableApplyAdapter, RecoverableRollbackAdapter,
    RecoverableConnectionAdapter
{
    let id = "durability-file"
    let version = "1"
    let payloadVersion = "1"

    private let stateURL: URL

    init(stateURL: URL) {
        self.stateURL = stateURL
    }

    static func initializeState(at url: URL) throws {
        try saveState(
            SyntheticState(configuration: userOwnedConfiguration, connected: false),
            at: url
        )
    }

    static func loadState(at url: URL) throws -> SyntheticState {
        try JSONDecoder().decode(SyntheticState.self, from: Data(contentsOf: url))
    }

    func prepareConnection(
        instance: ConnectedTargetInstance,
        approveLinkedSource: Bool
    ) async throws -> ConnectionPlan {
        let state = try Self.loadState(at: stateURL)
        return ConnectionPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            capturedPreChangeState: state.configuration,
            intendedChangeDigest: "connected",
            staleStateToken: token(for: state)
        )
    }

    func connect(_ plan: ConnectionPlan) async throws -> ConnectionReceipt {
        try await revalidateConnection(plan: plan)
        let state = try Self.loadState(at: stateURL)
        try Self.saveState(
            SyntheticState(configuration: state.configuration, connected: true),
            at: stateURL
        )
        return ConnectionReceipt(configurationState: .updated, detail: "connected")
    }

    func revalidateConnection(plan: ConnectionPlan) async throws {
        let state = try Self.loadState(at: stateURL)
        guard !state.connected, plan.staleStateToken == token(for: state) else {
            throw WriteBoundaryConflict(
                targetInstanceID: plan.targetInstanceID,
                detail: "connection state changed"
            )
        }
    }

    func classifyConnection(plan: ConnectionPlan) async throws -> ReconciliationClassification {
        let state = try Self.loadState(at: stateURL)
        if !state.connected, state.configuration == plan.capturedPreChangeState {
            return .beforeChange
        }
        if state.connected {
            return .intendedAfterChange
        }
        return .conflicting
    }

    func recoverConnectionReceipt(plan: ConnectionPlan) async throws -> ConnectionReceipt {
        guard try await classifyConnection(plan: plan) == .intendedAfterChange else {
            throw AdapterError.recoveryMismatch
        }
        return ConnectionReceipt(configurationState: .updated, detail: "connection recovered")
    }

    func prepareApply(
        instance: ConnectedTargetInstance,
        theme: PreparedTheme
    ) async throws -> AdapterPlan {
        let state = try Self.loadState(at: stateURL)
        return AdapterPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            capabilityID: "theme",
            payload: AdapterPayloadEnvelope(
                adapterID: id,
                adapterVersion: version,
                payloadVersion: payloadVersion,
                payload: themeConfiguration
            ),
            intendedChangeDigest: ContentAddressedStore.digest(of: themeConfiguration),
            capturedPreChangeState: state.configuration,
            staleStateToken: token(for: state),
            sourceType: theme.sourceType,
            sourceRevision: theme.sourceRevision,
            activationReach: .currentInstances
        )
    }

    func revalidateApply(plan: AdapterPlan) async throws {
        let state = try Self.loadState(at: stateURL)
        guard state.connected, plan.staleStateToken == token(for: state) else {
            throw WriteBoundaryConflict(
                targetInstanceID: plan.targetInstanceID,
                detail: "apply state changed"
            )
        }
    }

    func apply(_ plan: AdapterPlan) async throws -> AdapterReceipt {
        try await revalidateApply(plan: plan)
        let state = try Self.loadState(at: stateURL)
        try Self.saveState(
            SyntheticState(configuration: plan.payload.payload, connected: state.connected),
            at: stateURL
        )
        return AdapterReceipt(
            configurationState: .updated,
            runningInstanceReach: .currentInstances,
            detail: "theme applied"
        )
    }

    func classifyApply(plan: AdapterPlan) async throws -> ReconciliationClassification {
        let state = try Self.loadState(at: stateURL)
        if state.configuration == plan.capturedPreChangeState {
            return .beforeChange
        }
        if state.configuration == plan.payload.payload {
            return .intendedAfterChange
        }
        return .conflicting
    }

    func recoverApplyReceipt(plan: AdapterPlan) async throws -> AdapterReceipt {
        guard try await classifyApply(plan: plan) == .intendedAfterChange else {
            throw AdapterError.recoveryMismatch
        }
        return AdapterReceipt(
            configurationState: .updated,
            runningInstanceReach: .currentInstances,
            detail: "apply recovered"
        )
    }

    func rollbackApply(plan: AdapterPlan, receipt: AdapterReceipt) async throws {
        _ = try await rollbackApplyWithReceipt(plan: plan, receipt: receipt)
    }

    func rollbackApplyWithReceipt(
        plan: AdapterPlan,
        receipt: AdapterReceipt
    ) async throws -> AdapterReceipt {
        let state = try Self.loadState(at: stateURL)
        guard state.configuration == plan.payload.payload,
            let captured = plan.capturedPreChangeState
        else {
            throw AdapterError.rollbackRefused
        }
        try Self.saveState(
            SyntheticState(configuration: captured, connected: state.connected),
            at: stateURL
        )
        return AdapterReceipt(
            configurationState: .updated,
            runningInstanceReach: .currentInstances,
            detail: "apply rolled back"
        )
    }

    func recoverRollbackReceipt(
        plan: AdapterPlan,
        originalReceipt: AdapterReceipt
    ) async throws -> AdapterReceipt {
        let state = try Self.loadState(at: stateURL)
        guard state.configuration == plan.capturedPreChangeState else {
            throw AdapterError.recoveryMismatch
        }
        return AdapterReceipt(
            configurationState: .updated,
            runningInstanceReach: .currentInstances,
            detail: "rollback recovered"
        )
    }

    func restoreConnection(
        instance: ConnectedTargetInstance,
        baseline: Data
    ) async throws -> ConnectionReceipt {
        let state = try Self.loadState(at: stateURL)
        guard state.connected else { throw AdapterError.notConnected }
        try Self.saveState(
            SyntheticState(configuration: baseline, connected: true),
            at: stateURL
        )
        return ConnectionReceipt(configurationState: .updated, detail: "baseline restored")
    }

    func prepareDisconnect(
        instance: ConnectedTargetInstance,
        baseline: StoredConnectionBaseline,
        baselineData: Data
    ) async throws -> DisconnectPlan {
        let state = try Self.loadState(at: stateURL)
        return DisconnectPlan(
            targetInstanceID: instance.id,
            adapterID: id,
            adapterVersion: version,
            baselineReference: baseline.baselineReference,
            staleStateToken: token(for: state),
            opaquePayload: baselineData
        )
    }

    func revalidateDisconnect(plan: DisconnectPlan) async throws {
        let state = try Self.loadState(at: stateURL)
        guard state.connected, plan.staleStateToken == token(for: state) else {
            throw WriteBoundaryConflict(
                targetInstanceID: plan.targetInstanceID,
                detail: "disconnect state changed"
            )
        }
    }

    func classifyDisconnect(plan: DisconnectPlan) async throws -> ReconciliationClassification {
        let state = try Self.loadState(at: stateURL)
        if state.connected {
            return .beforeChange
        }
        if !state.connected, state.configuration == plan.opaquePayload {
            return .intendedAfterChange
        }
        return .conflicting
    }

    func disconnect(_ plan: DisconnectPlan, baseline: Data) async throws -> AdapterReceipt {
        try await revalidateDisconnect(plan: plan)
        try Self.saveState(
            SyntheticState(configuration: baseline, connected: false),
            at: stateURL
        )
        return AdapterReceipt(
            configurationState: .updated,
            runningInstanceReach: .currentInstances,
            detail: "disconnected"
        )
    }

    private static func saveState(_ state: SyntheticState, at url: URL) throws {
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
    }

    private func token(for state: SyntheticState) -> String {
        "\(state.connected):\(ContentAddressedStore.digest(of: state.configuration))"
    }
}

private enum AdapterError: Error {
    case notConnected
    case rollbackRefused
    case recoveryMismatch
}

private enum HarnessError: Error {
    case invalidArguments
    case checkpointNotReached(Int)
}

private let userOwnedConfiguration = Data([
    0x75, 0x73, 0x65, 0x72, 0x00, 0xff, 0x0a, 0x63, 0x6f, 0x6e, 0x66, 0x69, 0x67,
])
private let themeConfiguration = Data("managed-theme-configuration".utf8)
private let instance = ConnectedTargetInstance(
    id: TargetInstanceID(rawValue: "durability-file.default"),
    displayName: "Durability file target",
    adapterID: "durability-file"
)
private let disconnectedWorkspace = Workspace(
    id: .myMac,
    displayName: "My Mac",
    connectedTargetInstances: [],
    themeAssignment: .fixed(variantID: "durability/dark")
)
private let connectedWorkspace = Workspace(
    id: .myMac,
    displayName: "My Mac",
    connectedTargetInstances: [instance],
    themeAssignment: .fixed(variantID: "durability/dark")
)
private let fixturePack = ThemePack(
    schemaVersion: 1,
    id: "durability",
    displayName: "Durability",
    author: "Test",
    source: ThemeSource(
        type: .generated,
        url: URL(string: "https://example.invalid/durability")!,
        revision: "1",
        license: "test-only",
        attribution: "test fixture"
    ),
    variants: [
        ThemeVariant(
            id: "dark",
            displayName: "Dark",
            appearance: .dark,
            contentDigest: ContentAddressedStore.digest(of: themeConfiguration),
            roles: Dictionary(
                uniqueKeysWithValues: SemanticRole.allCases.map {
                    ($0, ThemeColor(rawValue: "#112233"))
                }
            )
        )
    ]
)
