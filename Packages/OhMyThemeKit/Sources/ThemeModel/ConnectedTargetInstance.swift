/// A Target Instance whose one-time setup and ownership scope the user has accepted,
/// allowing later theme changes without repeated setup confirmation.
public struct ConnectedTargetInstance: Codable, Sendable, Equatable, Identifiable {
    public let id: TargetInstanceID
    public let displayName: String
    public let adapterID: String

    public init(id: TargetInstanceID, displayName: String, adapterID: String) {
        self.id = id
        self.displayName = displayName
        self.adapterID = adapterID
    }
}

/// A stable identifier for a specific configuration context of a Target, such as a
/// VS Code profile or a Ghostty configuration.
public enum WorkspaceTargetOrder {
    public static func rank(adapterID: String) -> Int {
        switch adapterID {
        case "macos.appearance": 0
        case "macos.wallpaper": 1
        case "ghostty": 2
        case "vscode": 3
        case "starship": 4
        default: 100
        }
    }

    public static func ordered(
        _ instances: [ConnectedTargetInstance]
    ) -> [ConnectedTargetInstance] {
        instances.sorted { left, right in
            let leftRank = rank(adapterID: left.adapterID)
            let rightRank = rank(adapterID: right.adapterID)
            if leftRank != rightRank { return leftRank < rightRank }
            if left.adapterID != right.adapterID { return left.adapterID < right.adapterID }
            return left.id.rawValue < right.id.rawValue
        }
    }
}

public struct TargetInstanceID: Codable, Sendable, Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
