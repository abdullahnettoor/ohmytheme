import Foundation
import Persistence
import ThemeModel

/// Supplies the Workspace the menu bar presents.
///
/// The beta has exactly one Workspace, backed by SQLite so assignments and connections
/// survive application relaunch.
final class WorkspaceStore {
    private let persistence: PersistenceStore?

    init() {
        persistence = try? Self.makePersistenceStore()
        if let persistence, (try? persistence.loadWorkspace()) == nil {
            try? persistence.saveWorkspace(.myMac)
        }
    }

    var workspace: Workspace {
        guard let persistence, let state = try? persistence.loadWorkspace() else { return .myMac }
        return state.workspace
    }

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
        try? persistence?.saveWorkspace(updated)
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
