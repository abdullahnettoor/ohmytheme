/// A stable identifier for a ``Workspace`` that survives relaunches and schema changes.
public struct WorkspaceID: Sendable, Hashable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The identifier of the Workspace every installation starts with.
    public static let myMac = WorkspaceID(rawValue: "my-mac")
}
