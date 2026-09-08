import Foundation

/// The reason a discovered target instance is excluded from Select All Recommended.
public enum RecommendationExclusionReason: String, Codable, Equatable, Sendable, CaseIterable {
    case unavailable = "Unavailable"
    case ambiguous = "Ambiguous"
    case conflicting = "Conflicting"
    case experimental = "Experimental"
    case nonAllowlisted = "Non-allowlisted"
}

/// The eligibility rules for offering discovered target instances through Select All Recommended.
/// A stable-adapter allowlist sets the upper bound, while runtime discovery excludes
/// ambiguous, conflicting, experimental, and unavailable instances.
public enum RecommendedTargetPolicy: Sendable {
    /// The stable-adapter allowlist sets the upper bound of eligible adapters.
    public static let stableAdapterAllowlist: Set<String> = [
        "macos.appearance",
        "macos.wallpaper",
        "ghostty",
        "vscode",
        "starship",
    ]

    /// Checks whether an adapter ID is part of the stable-adapter allowlist.
    public static func isAllowlisted(adapterID: String) -> Bool {
        stableAdapterAllowlist.contains(adapterID)
    }

    /// Evaluates whether a target instance qualifies as recommended.
    public static func evaluate(
        adapterID: String,
        isAvailable: Bool,
        isAmbiguous: Bool = false,
        isConflicting: Bool = false,
        isExperimental: Bool = false
    ) -> (isRecommended: Bool, exclusionReason: RecommendationExclusionReason?) {
        if !isAvailable {
            return (false, .unavailable)
        }
        if isAmbiguous {
            return (false, .ambiguous)
        }
        if isConflicting {
            return (false, .conflicting)
        }
        if isExperimental {
            return (false, .experimental)
        }
        if !stableAdapterAllowlist.contains(adapterID) {
            return (false, .nonAllowlisted)
        }
        return (true, nil)
    }
}
