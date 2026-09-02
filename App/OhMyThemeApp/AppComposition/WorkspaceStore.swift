import ThemeModel

/// Supplies the Workspace the menu bar presents.
///
/// The beta has exactly one Workspace. Durable storage arrives with the persistence work,
/// so this launch-scoped store returns the first-run Workspace.
struct WorkspaceStore {
    var workspace: Workspace { .myMac }

    var appWorkspace: Workspace {
        #if DEBUG
        return Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "recording.debug"),
                    displayName: "Recording Target",
                    adapterID: "recording"
                )
            ]
        )
        #else
        return workspace
        #endif
    }
}
