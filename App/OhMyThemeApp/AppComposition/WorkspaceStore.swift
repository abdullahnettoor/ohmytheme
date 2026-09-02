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

    init() {
        do {
            let store = try Self.makePersistenceStore()
            do {
                _ = try store.loadWorkspace()
            } catch PersistenceError.workspaceNotFound {
                try store.saveWorkspace(.myMac)
            }
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

    var appWorkspace: Workspace {
        let persisted = workspace
        #if DEBUG
        guard persisted.connectedTargetInstances.isEmpty else { return persisted }
        return Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "recording.debug"),
                    displayName: "Recording Target",
                    adapterID: "recording"
                )
            ],
            themeAssignment: persisted.themeAssignment
        )
        #else
        return persisted
        #endif
    }

    func selectFixedVariant(_ variantID: String) {
        let current = workspace
        let updated = Workspace(
            id: current.id,
            displayName: current.displayName,
            connectedTargetInstances: current.connectedTargetInstances,
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
