/// The theme choice followed by a Workspace.
public enum ThemeAssignment: Codable, Equatable, Sendable {
    case fixed(variantID: String)
    case appearancePair(lightVariantID: String, darkVariantID: String)
}
