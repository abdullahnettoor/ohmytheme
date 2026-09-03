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
