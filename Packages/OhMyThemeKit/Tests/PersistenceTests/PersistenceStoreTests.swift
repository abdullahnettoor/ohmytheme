import Foundation
import GRDB
import Persistence
import Testing
import ThemeModel

@Suite("Durable Workspace Persistence")
struct PersistenceStoreTests {
    @Test("Initial migration creates a database that round trips Workspace assignment and target state")
    func workspaceRoundTrip() throws {
        let fixture = try Fixture()
        let targets = [
            PersistedTargetInstance(
                id: TargetInstanceID(rawValue: "vscode.default"),
                displayName: "Visual Studio Code",
                adapterID: "vscode",
                isConnected: true
            ),
            PersistedTargetInstance(
                id: TargetInstanceID(rawValue: "ghostty.default"),
                displayName: "Ghostty",
                adapterID: "ghostty",
                isConnected: false
            ),
        ]
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: targets[0].id,
                    displayName: targets[0].displayName,
                    adapterID: targets[0].adapterID
                )
            ],
            themeAssignment: .appearancePair(
                lightVariantID: "aurora/light",
                darkVariantID: "aurora/dark"
            )
        )

        try fixture.store.saveWorkspace(workspace, targetInstances: targets)
        let restored = try fixture.store.loadWorkspace()

        #expect(restored.workspace == workspace)
        let canonicalTargets = [targets[1], targets[0]]
        #expect(restored.targetInstances == canonicalTargets)

        let updated = Workspace(
            id: workspace.id,
            displayName: workspace.displayName,
            connectedTargetInstances: workspace.connectedTargetInstances,
            themeAssignment: .fixed(variantID: "aurora/light")
        )
        try fixture.store.saveWorkspace(updated)
        #expect(try fixture.store.loadWorkspace().targetInstances == canonicalTargets)
    }

    @Test("Fixed assignments survive a fresh PersistenceStore instance")
    func fixedAssignmentSurvivesRelaunch() throws {
        let fixture = try Fixture()
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            themeAssignment: .fixed(variantID: "catppuccin/mocha")
        )
        try fixture.store.saveWorkspace(workspace)

        let reopened = try PersistenceStore(databaseURL: fixture.databaseURL, contentStoreURL: fixture.contentURL)

        #expect(try reopened.loadWorkspace().workspace.themeAssignment == workspace.themeAssignment)
    }

    @Test("Payload envelopes and exact bytes are content addressed")
    func payloadEnvelopeRoundTrip() throws {
        let fixture = try Fixture()
        let bytes = Data([0, 1, 2, 255, 13, 10])
        let envelope = PersistedPayloadEnvelope(
            id: "plan-1",
            targetInstanceID: TargetInstanceID(rawValue: "recording.debug"),
            adapterID: "recording",
            adapterVersion: "1",
            payloadVersion: "1",
            payload: bytes
        )
        let restoration = Data("baseline".utf8)

        _ = try fixture.store.savePayloadEnvelope(envelope, restorationData: restoration)
        let restored = try fixture.store.loadPayloadEnvelope(id: envelope.id)

        #expect(restored.payload == envelope.payload)
        #expect(restored.restorationReference?.digest == ContentAddressedStore.digest(of: restoration))
        #expect(try fixture.store.loadRestorationContent(forEnvelopeID: envelope.id) == restoration)
        let reference = try fixture.store.saveContent(bytes, kind: "restoration", ownerID: "baseline-1")
        #expect(reference.digest == ContentAddressedStore.digest(of: bytes))
        #expect(try fixture.store.loadContent(reference) == bytes)
    }

    @Test("Existing databases migrate payload envelopes to include restoration references")
    func legacyPayloadEnvelopeSchemaMigrates() throws {
        let fixture = try LegacyFixture()
        #expect(
            try fixture.store.loadPayloadEnvelope(id: fixture.legacyEnvelopeID).payload == fixture.legacyPayload
        )
        let envelope = PersistedPayloadEnvelope(
            id: "legacy-plan-1",
            targetInstanceID: TargetInstanceID(rawValue: "recording.debug"),
            adapterID: "recording",
            adapterVersion: "1",
            payloadVersion: "1",
            payload: Data("prepared-artifact".utf8)
        )
        let restoration = Data("legacy-baseline".utf8)

        _ = try fixture.store.savePayloadEnvelope(envelope, restorationData: restoration)

        #expect(try fixture.store.loadRestorationContent(forEnvelopeID: envelope.id) == restoration)
        #expect(try fixture.store.journalInterruptedOperations().isEmpty)
    }

    @Test("Pre-rename Apply journal rows and recovery content remain readable")
    func preRenameApplyJournalRemainsReadable() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-theme-pre-rename-persistence-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = directoryURL.appendingPathComponent("state.sqlite")
        let contentURL = directoryURL.appendingPathComponent("recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let completedOperationID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let interruptedOperationID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let completedTargetID = "recording.pre-rename-completed"
        let interruptedTargetID = "recording.pre-rename-interrupted"
        let completedCreatedAt = 1_700_000_000.0
        let interruptedCreatedAt = 1_700_000_100.0
        let completedReceipt =
            "{\"configurationState\":\"updated\",\"runningInstanceReach\":\"currentInstances\"}"
        let planPayload = Data("pre-rename-apply-plan".utf8)
        let recoveryData = Data("pre-rename-recovery-state".utf8)
        let contentStore = try ContentAddressedStore(rootURL: contentURL)
        let planReference = try contentStore.put(planPayload)
        let recoveryReference = try contentStore.put(recoveryData)

        var migrator = DatabaseMigrator()
        migrator.registerMigration("initial") { database in
            try database.create(table: "workspaces") { table in
                table.column("id", .text).primaryKey()
                table.column("display_name", .text).notNull()
            }
            try database.create(table: "theme_assignments") { table in
                table.column("workspace_id", .text).primaryKey().references("workspaces", onDelete: .cascade)
                table.column("kind", .text).notNull()
                table.column("fixed_variant_id", .text)
                table.column("light_variant_id", .text)
                table.column("dark_variant_id", .text)
            }
            try database.create(table: "target_instances") { table in
                table.column("id", .text).primaryKey()
                table.column("workspace_id", .text).notNull().references("workspaces", onDelete: .cascade)
                table.column("display_name", .text).notNull()
                table.column("adapter_id", .text).notNull()
                table.column("is_connected", .boolean).notNull()
            }
            try database.create(table: "content_references") { table in
                table.column("digest", .text).primaryKey()
                table.column("byte_count", .integer).notNull()
                table.column("kind", .text).notNull()
                table.column("owner_id", .text).notNull()
            }
            try database.create(table: "payload_envelopes") { table in
                table.column("id", .text).primaryKey()
                table.column("target_instance_id", .text).notNull()
                table.column("adapter_id", .text).notNull()
                table.column("adapter_version", .text).notNull()
                table.column("payload_version", .text).notNull()
                table.column("payload_digest", .text).notNull().references("content_references")
                table.column("restoration_digest", .text).references("content_references")
            }
            try database.create(table: "operations") { table in
                table.column("id", .text).primaryKey()
                table.column("kind", .text).notNull()
                table.column("state", .text).notNull()
                table.column("workspace_id", .text).notNull()
                table.column("variant_id", .text)
                table.column("created_at", .double).notNull()
            }
            try database.create(table: "operation_records") { table in
                table.column("operation_id", .text).notNull()
                    .references("operations", onDelete: .cascade)
                table.column("target_instance_id", .text).notNull()
                table.column("ordinal", .integer).notNull()
                table.column("adapter_id", .text).notNull()
                table.column("adapter_version", .text).notNull()
                table.column("capability_id", .text).notNull()
                table.column("phase", .text).notNull()
                table.column("intended_change_digest", .text).notNull()
                table.column("stale_state_token", .text)
                table.column("plan_digest", .text)
                table.column("receipt_json", .text)
                table.column("detail", .text)
                table.primaryKey(["operation_id", "target_instance_id"])
            }
            try database.create(table: "connection_baselines") { table in
                table.column("target_instance_id", .text).primaryKey()
                table.column("adapter_id", .text).notNull()
                table.column("adapter_version", .text).notNull()
                table.column("baseline_digest", .text).notNull()
                table.column("captured_at", .double).notNull()
            }
        }
        migrator.registerMigration("add-payload-restoration-digest") { _ in }
        migrator.registerMigration("add-durable-operation-journal") { _ in }

        let preRenameDatabase = try DatabaseQueue(path: databaseURL.path)
        try migrator.migrate(preRenameDatabase)
        try preRenameDatabase.write { database in
            try database.execute(
                sql: """
                    INSERT INTO content_references (digest, byte_count, kind, owner_id)
                    VALUES (?, ?, 'adapter-plan', ?), (?, ?, 'restoration', ?)
                    """,
                arguments: [
                    planReference.digest,
                    planReference.byteCount,
                    "apply.\(interruptedOperationID.uuidString).\(interruptedTargetID)",
                    recoveryReference.digest,
                    recoveryReference.byteCount,
                    "apply.\(interruptedOperationID.uuidString).recovery",
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO operations (id, kind, state, workspace_id, variant_id, created_at)
                    VALUES (?, 'apply', 'applied', 'my-mac', 'aurora/dark', ?),
                           (?, 'apply', 'applying', 'my-mac', 'aurora/light', ?)
                    """,
                arguments: [
                    completedOperationID.uuidString,
                    completedCreatedAt,
                    interruptedOperationID.uuidString,
                    interruptedCreatedAt,
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO operation_records (
                        operation_id, target_instance_id, ordinal,
                        adapter_id, adapter_version, capability_id, phase,
                        intended_change_digest, stale_state_token,
                        plan_digest, receipt_json, detail
                    ) VALUES
                        (?, ?, 0, 'recording', '1', 'theme', 'applied',
                         'sha256:completed-intended', 'completed-token', NULL, ?, NULL),
                        (?, ?, 0, 'recording', '1', 'theme', 'applying',
                         'sha256:interrupted-intended', 'interrupted-token', ?, NULL, NULL)
                    """,
                arguments: [
                    completedOperationID.uuidString,
                    completedTargetID,
                    completedReceipt,
                    interruptedOperationID.uuidString,
                    interruptedTargetID,
                    planReference.digest,
                ]
            )
        }

        let store = try PersistenceStore(databaseURL: databaseURL, contentStoreURL: contentURL)

        let lastApply = try store.journalFindLastAppliedTransaction(workspaceID: .myMac)
        #expect(lastApply?.id == completedOperationID)
        #expect(lastApply?.kind == .apply)
        #expect(lastApply?.state == .applied)
        #expect(lastApply?.variantID == "aurora/dark")
        #expect(lastApply?.createdAt == Date(timeIntervalSince1970: completedCreatedAt))

        let completedRecords = try store.journalLoadRecords(operationID: completedOperationID)
        #expect(completedRecords.count == 1)
        #expect(completedRecords.first?.targetInstanceID.rawValue == completedTargetID)
        #expect(completedRecords.first?.phase == .applied)
        #expect(completedRecords.first?.receiptJSON == completedReceipt)

        let interruptedOperations = try store.journalInterruptedOperations()
        #expect(interruptedOperations.count == 1)
        #expect(interruptedOperations.first?.id == interruptedOperationID)
        #expect(interruptedOperations.first?.kind == .apply)
        #expect(interruptedOperations.first?.state == .applying)
        #expect(interruptedOperations.first?.variantID == "aurora/light")
        #expect(interruptedOperations.first?.createdAt == Date(timeIntervalSince1970: interruptedCreatedAt))

        let interruptedRecords = try store.journalLoadRecords(operationID: interruptedOperationID)
        #expect(interruptedRecords.count == 1)
        #expect(interruptedRecords.first?.targetInstanceID.rawValue == interruptedTargetID)
        #expect(interruptedRecords.first?.phase == .applying)
        #expect(interruptedRecords.first?.planDigest == planReference.digest)
        #expect(try store.journalLoadPlanPayload(planReference) == planPayload)
        #expect(try store.journalLoadContent(digest: recoveryReference.digest) == recoveryData)
    }

    @Test("Content store uses user-only permissions and rejects tampering")
    func contentStoreProtectsAndVerifiesBytes() throws {
        let fixture = try Fixture()
        let bytes = Data("sensitive baseline".utf8)
        let reference = try fixture.store.contentStore.put(bytes)
        let fileURL = try fixture.store.contentStore.fileURL(for: reference)
        let recoveryPermissions = try fixture.permissions(of: fixture.contentURL)
        let databasePermissions = try fixture.permissions(of: fixture.databaseURL)
        let directoryPermissions = try fixture.permissions(of: fileURL.deletingLastPathComponent())
        let filePermissions = try fixture.permissions(of: fileURL)

        #expect(recoveryPermissions == 0o700)
        #expect(databasePermissions == 0o600)
        #expect(directoryPermissions == 0o700)
        #expect(filePermissions == 0o600)
        #expect(try fixture.store.contentStore.get(reference) == bytes)

        try Data("tampered".utf8).write(to: fileURL)
        #expect(throws: ContentStoreError.self) {
            try fixture.store.contentStore.get(reference)
        }
    }

    private struct Fixture {
        let directoryURL: URL
        let databaseURL: URL
        let contentURL: URL
        let store: PersistenceStore

        init() throws {
            directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("oh-my-theme-persistence-\(UUID().uuidString)", isDirectory: true)
            databaseURL = directoryURL.appendingPathComponent("state.sqlite")
            contentURL = directoryURL.appendingPathComponent("recovery", isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            store = try PersistenceStore(databaseURL: databaseURL, contentStoreURL: contentURL)
        }

        func permissions(of url: URL) throws -> Int {
            let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
            return value.intValue & 0o777
        }
    }

    private struct LegacyFixture {
        let directoryURL: URL
        let databaseURL: URL
        let contentURL: URL
        let legacyEnvelopeID: String
        let legacyPayload: Data
        let store: PersistenceStore

        init() throws {
            directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("oh-my-theme-legacy-persistence-\(UUID().uuidString)", isDirectory: true)
            databaseURL = directoryURL.appendingPathComponent("state.sqlite")
            contentURL = directoryURL.appendingPathComponent("recovery", isDirectory: true)
            let legacyEnvelopeID = "legacy-existing-plan"
            let legacyPayload = Data("legacy-prepared-artifact".utf8)
            self.legacyEnvelopeID = legacyEnvelopeID
            self.legacyPayload = legacyPayload
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            var migrator = DatabaseMigrator()
            migrator.registerMigration("initial") { database in
                try database.create(table: "content_references") { table in
                    table.column("digest", .text).primaryKey()
                    table.column("byte_count", .integer).notNull()
                    table.column("kind", .text).notNull()
                    table.column("owner_id", .text).notNull()
                }
                try database.create(table: "payload_envelopes") { table in
                    table.column("id", .text).primaryKey()
                    table.column("target_instance_id", .text).notNull()
                    table.column("adapter_id", .text).notNull()
                    table.column("adapter_version", .text).notNull()
                    table.column("payload_version", .text).notNull()
                    table.column("payload_digest", .text).notNull().references("content_references")
                }
            }
            let legacyDatabase = try DatabaseQueue(path: databaseURL.path)
            try migrator.migrate(legacyDatabase)
            let contentStore = try ContentAddressedStore(rootURL: contentURL)
            let payloadReference = try contentStore.put(legacyPayload)
            try legacyDatabase.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO content_references (digest, byte_count, kind, owner_id)
                        VALUES (?, ?, 'generated-artifact', ?)
                        """,
                    arguments: [payloadReference.digest, payloadReference.byteCount, legacyEnvelopeID]
                )
                try database.execute(
                    sql: """
                        INSERT INTO payload_envelopes
                        (id, target_instance_id, adapter_id, adapter_version, payload_version, payload_digest)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        legacyEnvelopeID,
                        "recording.debug",
                        "recording",
                        "1",
                        "1",
                        payloadReference.digest,
                    ]
                )
            }
            store = try PersistenceStore(databaseURL: databaseURL, contentStoreURL: contentURL)
        }
    }
}
