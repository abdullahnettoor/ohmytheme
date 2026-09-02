/// The user's selected set of Connected Target Instances that follow the same Theme Assignment.
///
/// The beta persists exactly one Workspace, presented as "My Mac".
public struct Workspace: Codable, Sendable, Equatable, Identifiable {
    public let id: WorkspaceID
    public let displayName: String
    public let connectedTargetInstances: [ConnectedTargetInstance]
    public let themeAssignment: ThemeAssignment?

    public init(
        id: WorkspaceID,
        displayName: String,
        connectedTargetInstances: [ConnectedTargetInstance] = [],
        themeAssignment: ThemeAssignment? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.connectedTargetInstances = connectedTargetInstances
        self.themeAssignment = themeAssignment
    }

    /// The single Workspace every installation starts with, before anything is connected.
    public static let myMac = Workspace(id: .myMac, displayName: "My Mac")
}
