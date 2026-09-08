import Foundation
import Persistence
import ThemeModel

/// Supplies the Workspace the menu bar presents.
///
/// The beta has exactly one Workspace, backed by SQLite so assignments and connections
/// survive application relaunch.
final class WorkspaceStore {
    private let persistence: PersistenceStore?
    private(set) var persistenceError: String?

    init(persistenceStore: PersistenceStore? = nil) {
        if let persistenceStore {
            persistence = persistenceStore
            do {
                try Self.ensureWorkspaceExists(in: persistenceStore)
            } catch {
                persistenceError = String(describing: error)
            }
            return
        }
        do {
            let store = try Self.makePersistenceStore()
            try Self.ensureWorkspaceExists(in: store)
            persistence = store
        } catch {
            persistence = nil
            persistenceError = String(describing: error)
        }
    }

    var workspace: Workspace {
        guard let persistence else { return .myMac }
        do {
            return try persistence.loadWorkspace().workspace
        } catch {
            persistenceError = String(describing: error)
            return .myMac
        }
    }

    var persistenceStore: PersistenceStore? { persistence }

    var targetInstances: [PersistedTargetInstance] {
        (try? persistence?.loadWorkspace().targetInstances) ?? []
    }

    func selectFixedVariant(_ variantID: String) {
        let current = workspace
        let updated = Workspace(
            id: current.id,
            displayName: current.displayName,
            connectedTargetInstances: current.connectedTargetInstances,
            targetOptIns: current.targetOptIns,
            themeAssignment: .fixed(variantID: variantID)
        )
        guard let persistence else {
            persistenceError = persistenceError ?? "Workspace persistence is unavailable."
            return
        }
        do {
            try persistence.saveWorkspace(updated)
        } catch {
            persistenceError = String(describing: error)
        }
    }

    func setTargetOptIn(instance: ConnectedTargetInstance, isOptedIn: Bool) {
        var optIns = workspace.targetOptIns
        if isOptedIn {
            optIns.insert(instance.id)
        } else {
            optIns.remove(instance.id)
        }
        setTargetOptIns(optIns, discoveredInstances: [instance])
    }

    func setTargetOptIns(
        _ optIns: Set<TargetInstanceID>,
        discoveredInstances: [ConnectedTargetInstance] = []
    ) {
        guard let persistence else {
            persistenceError = persistenceError ?? "Workspace persistence is unavailable."
            return
        }
        do {
            let current = workspace
            let updated = Workspace(
                id: current.id,
                displayName: current.displayName,
                connectedTargetInstances: current.connectedTargetInstances,
                targetOptIns: optIns,
                themeAssignment: current.themeAssignment
            )
            var persistedInstancesByID = Dictionary(
                uniqueKeysWithValues: targetInstances.map { ($0.id, $0) }
            )
            for instance in current.connectedTargetInstances {
                persistedInstancesByID[instance.id] = PersistedTargetInstance(
                    id: instance.id,
                    displayName: instance.displayName,
                    adapterID: instance.adapterID,
                    isConnected: true,
                    isOptedIn: true
                )
            }
            for instance in discoveredInstances {
                persistedInstancesByID[instance.id] = PersistedTargetInstance(
                    id: instance.id,
                    displayName: instance.displayName,
                    adapterID: instance.adapterID,
                    isConnected: current.isConnected(instance.id),
                    isOptedIn: optIns.contains(instance.id)
                )
            }
            let persistedInstances = persistedInstancesByID.values.map { instance in
                PersistedTargetInstance(
                    id: instance.id,
                    displayName: instance.displayName,
                    adapterID: instance.adapterID,
                    isConnected: current.isConnected(instance.id),
                    isOptedIn: optIns.contains(instance.id)
                )
            }
            try persistence.saveWorkspace(updated, targetInstances: persistedInstances)
        } catch {
            persistenceError = String(describing: error)
        }
    }

    private static func ensureWorkspaceExists(in store: PersistenceStore) throws {
        do {
            _ = try store.loadWorkspace()
        } catch PersistenceError.workspaceNotFound {
            try store.saveWorkspace(.myMac)
        }
    }

    private static func makePersistenceStore() throws -> PersistenceStore {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = applicationSupport.appendingPathComponent("OhMyTheme", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let databaseURL = root.appendingPathComponent("workspace.sqlite")
        let store = try PersistenceStore(
            databaseURL: databaseURL,
            contentStoreURL: root.appendingPathComponent("Recovery", isDirectory: true)
        )
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
        }
        return store
    }
}
