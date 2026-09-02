import Foundation
import GRDB
import ThemeModel

public struct PersistedTargetInstance: Codable, Equatable, Sendable, Identifiable {
    public let id: TargetInstanceID
    public let displayName: String
    public let adapterID: String
    public let isConnected: Bool

    public init(id: TargetInstanceID, displayName: String, adapterID: String, isConnected: Bool) {
        self.id = id
        self.displayName = displayName
        self.adapterID = adapterID
        self.isConnected = isConnected
    }
}

public struct PersistedWorkspace: Codable, Equatable, Sendable {
    public let workspace: Workspace
    public let targetInstances: [PersistedTargetInstance]

    public init(workspace: Workspace, targetInstances: [PersistedTargetInstance]) {
        self.workspace = workspace
        self.targetInstances = targetInstances
    }
}

public struct PersistedPayloadEnvelope: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let targetInstanceID: TargetInstanceID
    public let adapterID: String
    public let adapterVersion: String
    public let payloadVersion: String
    public let payload: Data
    public let restorationReference: ContentReference?

    public init(
        id: String,
        targetInstanceID: TargetInstanceID,
        adapterID: String,
        adapterVersion: String,
        payloadVersion: String,
        payload: Data,
        restorationReference: ContentReference? = nil
    ) {
        self.id = id
        self.targetInstanceID = targetInstanceID
        self.adapterID = adapterID
        self.adapterVersion = adapterVersion
        self.payloadVersion = payloadVersion
        self.payload = payload
        self.restorationReference = restorationReference
    }
}

public enum PersistenceError: Error, Equatable, Sendable {
    case workspaceNotFound
    case payloadEnvelopeNotFound(String)
    case invalidAssignment
}

/// Focused durable state API for the one beta Workspace and its recovery content.
public final class PersistenceStore: @unchecked Sendable {
    public let contentStore: ContentAddressedStore

    private let database: DatabaseQueue

    public init(databaseURL: URL, contentStoreURL: URL) throws {
        contentStore = try ContentAddressedStore(rootURL: contentStoreURL)
        let databaseDirectory = databaseURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: databaseDirectory.path)
        database = try DatabaseQueue(path: databaseURL.path)
        if fileManager.fileExists(atPath: databaseURL.path) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        }
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
        try migrator.migrate(database)
    }

    func withWrite<T>(_ block: (Database) throws -> T) throws -> T {
        try database.write(block)
    }

    func withRead<T>(_ block: (Database) throws -> T) throws -> T {
        try database.read(block)
    }

    public func loadWorkspace() throws -> PersistedWorkspace {
        try database.read { database in
            guard
                let workspaceRow = try Row.fetchOne(
                    database,
                    sql: "SELECT id, display_name FROM workspaces ORDER BY id LIMIT 1"
                )
            else {
                throw PersistenceError.workspaceNotFound
            }
            let workspaceID = WorkspaceID(rawValue: workspaceRow["id"])
            let assignment = try Self.assignment(for: workspaceID, in: database)
            let targets = try Row.fetchAll(
                database,
                sql: """
                    SELECT id, display_name, adapter_id, is_connected
                    FROM target_instances WHERE workspace_id = ? ORDER BY rowid
                    """,
                arguments: [workspaceID.rawValue]
            ).map {
                PersistedTargetInstance(
                    id: TargetInstanceID(rawValue: $0["id"]),
                    displayName: $0["display_name"],
                    adapterID: $0["adapter_id"],
                    isConnected: ($0["is_connected"] as Int) != 0
                )
            }
            let connected = targets.filter(\.isConnected).map {
                ConnectedTargetInstance(id: $0.id, displayName: $0.displayName, adapterID: $0.adapterID)
            }
            return PersistedWorkspace(
                workspace: Workspace(
                    id: workspaceID,
                    displayName: workspaceRow["display_name"],
                    connectedTargetInstances: connected,
                    themeAssignment: assignment
                ),
                targetInstances: targets
            )
        }
    }

    public func saveWorkspace(
        _ workspace: Workspace,
        targetInstances: [PersistedTargetInstance]? = nil
    ) throws {
        try database.write { database in
            try database.execute(sql: "DELETE FROM theme_assignments")
            try database.execute(
                sql: """
                    INSERT INTO workspaces (id, display_name) VALUES (?, ?)
                    ON CONFLICT(id) DO UPDATE SET display_name = excluded.display_name
                    """,
                arguments: [workspace.id.rawValue, workspace.displayName]
            )
            if let assignment = workspace.themeAssignment {
                switch assignment {
                case .fixed(let variantID):
                    try database.execute(
                        sql: """
                            INSERT INTO theme_assignments
                            (workspace_id, kind, fixed_variant_id, light_variant_id, dark_variant_id)
                            VALUES (?, 'fixed', ?, NULL, NULL)
                            """,
                        arguments: [workspace.id.rawValue, variantID]
                    )
                case .appearancePair(let light, let dark):
                    try database.execute(
                        sql: """
                            INSERT INTO theme_assignments
                            (workspace_id, kind, fixed_variant_id, light_variant_id, dark_variant_id)
                            VALUES (?, 'appearance-pair', NULL, ?, ?)
                            """,
                        arguments: [workspace.id.rawValue, light, dark]
                    )
                }
            }
            if let targetInstances {
                try database.execute(
                    sql: "DELETE FROM target_instances WHERE workspace_id = ?",
                    arguments: [workspace.id.rawValue]
                )
                for instance in targetInstances {
                    try Self.insert(instance, workspaceID: workspace.id, in: database)
                }
            } else {
                for instance in workspace.connectedTargetInstances {
                    try Self.insert(
                        PersistedTargetInstance(
                            id: instance.id,
                            displayName: instance.displayName,
                            adapterID: instance.adapterID,
                            isConnected: true
                        ),
                        workspaceID: workspace.id,
                        in: database
                    )
                }
            }
        }
    }

    @discardableResult
    public func savePayloadEnvelope(_ envelope: PersistedPayloadEnvelope, restorationData: Data? = nil) throws -> String
    {
        let reference = try contentStore.put(envelope.payload)
        let restorationReference: ContentReference?
        if let restorationData {
            restorationReference = try contentStore.put(restorationData)
        } else if let existingReference = envelope.restorationReference {
            _ = try contentStore.get(existingReference)
            restorationReference = existingReference
        } else {
            restorationReference = nil
        }
        try database.write { database in
            try database.execute(
                sql: """
                    INSERT OR REPLACE INTO content_references (digest, byte_count, kind, owner_id)
                    VALUES (?, ?, 'generated-artifact', ?)
                    """,
                arguments: [reference.digest, reference.byteCount, envelope.id]
            )
            if let restorationReference {
                try database.execute(
                    sql: """
                        INSERT OR REPLACE INTO content_references (digest, byte_count, kind, owner_id)
                        VALUES (?, ?, 'restoration', ?)
                        """,
                    arguments: [restorationReference.digest, restorationReference.byteCount, envelope.id]
                )
            }
            try database.execute(
                sql: """
                    INSERT OR REPLACE INTO payload_envelopes
                    (id, target_instance_id, adapter_id, adapter_version, payload_version, payload_digest, restoration_digest)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    envelope.id,
                    envelope.targetInstanceID.rawValue,
                    envelope.adapterID,
                    envelope.adapterVersion,
                    envelope.payloadVersion,
                    reference.digest,
                    restorationReference?.digest,
                ]
            )
        }
        return envelope.id
    }

    public func loadPayloadEnvelope(id: String) throws -> PersistedPayloadEnvelope {
        try database.read { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT target_instance_id, adapter_id, adapter_version, payload_version, payload_digest
                            , restoration_digest
                        FROM payload_envelopes WHERE id = ?
                        """,
                    arguments: [id]
                )
            else {
                throw PersistenceError.payloadEnvelopeNotFound(id)
            }
            let digest: String = row["payload_digest"]
            let count: Int =
                try Row.fetchOne(
                    database,
                    sql: "SELECT byte_count FROM content_references WHERE digest = ?",
                    arguments: [digest]
                )?["byte_count"] ?? 0
            let payload = try contentStore.get(ContentReference(digest: digest, byteCount: count))
            let restorationReference: ContentReference?
            if let restorationDigest: String = row["restoration_digest"] {
                let restorationCount: Int =
                    try Row.fetchOne(
                        database,
                        sql: "SELECT byte_count FROM content_references WHERE digest = ?",
                        arguments: [restorationDigest]
                    )?["byte_count"] ?? 0
                restorationReference = ContentReference(digest: restorationDigest, byteCount: restorationCount)
            } else {
                restorationReference = nil
            }
            return PersistedPayloadEnvelope(
                id: id,
                targetInstanceID: TargetInstanceID(rawValue: row["target_instance_id"]),
                adapterID: row["adapter_id"],
                adapterVersion: row["adapter_version"],
                payloadVersion: row["payload_version"],
                payload: payload,
                restorationReference: restorationReference
            )
        }
    }

    public func loadRestorationContent(forEnvelopeID id: String) throws -> Data {
        let envelope = try loadPayloadEnvelope(id: id)
        guard let reference = envelope.restorationReference else {
            throw PersistenceError.payloadEnvelopeNotFound("\(id).restoration")
        }
        return try contentStore.get(reference)
    }

    @discardableResult
    public func saveContent(_ data: Data, kind: String, ownerID: String) throws -> ContentReference {
        let reference = try contentStore.put(data)
        try database.write { database in
            try database.execute(
                sql: """
                    INSERT OR REPLACE INTO content_references (digest, byte_count, kind, owner_id)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [reference.digest, reference.byteCount, kind, ownerID]
            )
        }
        return reference
    }

    public func loadContent(_ reference: ContentReference) throws -> Data {
        try contentStore.get(reference)
    }

    private static func insert(
        _ instance: PersistedTargetInstance,
        workspaceID: WorkspaceID,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO target_instances
                (id, workspace_id, display_name, adapter_id, is_connected)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                workspace_id = excluded.workspace_id,
                display_name = excluded.display_name,
                adapter_id = excluded.adapter_id,
                is_connected = excluded.is_connected
                """,
            arguments: [
                instance.id.rawValue,
                workspaceID.rawValue,
                instance.displayName,
                instance.adapterID,
                instance.isConnected,
            ]
        )
    }

    private static func assignment(for workspaceID: WorkspaceID, in database: Database) throws -> ThemeAssignment? {
        guard
            let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT kind, fixed_variant_id, light_variant_id, dark_variant_id
                    FROM theme_assignments WHERE workspace_id = ?
                    """,
                arguments: [workspaceID.rawValue]
            )
        else {
            return nil
        }
        let kind: String = row["kind"]
        switch kind {
        case "fixed":
            guard let variantID: String = row["fixed_variant_id"] else { throw PersistenceError.invalidAssignment }
            return .fixed(variantID: variantID)
        case "appearance-pair":
            guard let light: String = row["light_variant_id"],
                let dark: String = row["dark_variant_id"]
            else {
                throw PersistenceError.invalidAssignment
            }
            return .appearancePair(lightVariantID: light, darkVariantID: dark)
        default:
            throw PersistenceError.invalidAssignment
        }
    }
}
