import Foundation

/// The user's selected set of Connected Target Instances that follow the same Theme Assignment.
///
/// The beta persists exactly one Workspace, presented as "My Mac".
public struct Workspace: Codable, Sendable, Equatable, Identifiable {
    public let id: WorkspaceID
    public let displayName: String
    public let connectedTargetInstances: [ConnectedTargetInstance]
    public let targetOptIns: Set<TargetInstanceID>
    public let themeAssignment: ThemeAssignment?

    public init(
        id: WorkspaceID,
        displayName: String,
        connectedTargetInstances: [ConnectedTargetInstance] = [],
        targetOptIns: Set<TargetInstanceID> = [],
        themeAssignment: ThemeAssignment? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.connectedTargetInstances = connectedTargetInstances
        self.targetOptIns = targetOptIns.union(connectedTargetInstances.map(\.id))
        self.themeAssignment = themeAssignment
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case connectedTargetInstances
        case targetOptIns
        case themeAssignment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(WorkspaceID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        let connected =
            try container.decodeIfPresent([ConnectedTargetInstance].self, forKey: .connectedTargetInstances) ?? []
        connectedTargetInstances = connected
        let optIns = try container.decodeIfPresent(Set<TargetInstanceID>.self, forKey: .targetOptIns) ?? []
        targetOptIns = optIns.union(connected.map(\.id))
        themeAssignment = try container.decodeIfPresent(ThemeAssignment.self, forKey: .themeAssignment)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(connectedTargetInstances, forKey: .connectedTargetInstances)
        try container.encode(targetOptIns, forKey: .targetOptIns)
        try container.encodeIfPresent(themeAssignment, forKey: .themeAssignment)
    }

    /// Checks if a Target Instance is opted in.
    /// Connected target instances are always treated as opted in.
    public func isOptedIn(_ targetInstanceID: TargetInstanceID) -> Bool {
        targetOptIns.contains(targetInstanceID) || connectedTargetInstances.contains { $0.id == targetInstanceID }
    }

    /// Checks if a Target Instance is currently connected.
    public func isConnected(_ targetInstanceID: TargetInstanceID) -> Bool {
        connectedTargetInstances.contains { $0.id == targetInstanceID }
    }

    /// The single Workspace every installation starts with, before anything is connected.
    public static let myMac = Workspace(id: .myMac, displayName: "My Mac")
}
