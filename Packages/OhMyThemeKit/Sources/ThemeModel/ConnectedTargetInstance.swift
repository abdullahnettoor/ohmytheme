/// A Target Instance whose one-time setup and ownership scope the user has accepted,
/// allowing later theme changes without repeated setup confirmation.
public struct ConnectedTargetInstance: Sendable, Equatable, Identifiable {
    public let id: TargetInstanceID
    public let displayName: String
    public let adapterID: String

    public init(id: TargetInstanceID, displayName: String, adapterID: String = "recording") {
        self.id = id
        self.displayName = displayName
        self.adapterID = adapterID
    }
}

/// A stable identifier for a specific configuration context of a Target, such as a
/// VS Code profile or a Ghostty configuration.
public struct TargetInstanceID: Codable, Sendable, Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
