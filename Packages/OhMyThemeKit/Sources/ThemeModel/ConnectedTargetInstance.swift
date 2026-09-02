/// A Target Instance whose one-time setup and ownership scope the user has accepted,
/// allowing later theme changes without repeated setup confirmation.
public struct ConnectedTargetInstance: Sendable, Equatable, Identifiable {
    public let id: TargetInstanceID
    public let displayName: String

    public init(id: TargetInstanceID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// A stable identifier for a specific configuration context of a Target, such as a
/// VS Code profile or a Ghostty configuration.
public struct TargetInstanceID: Sendable, Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}
