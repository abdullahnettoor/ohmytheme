import Foundation

/// A versioned, data-only collection of Theme Variants.
public struct ThemePack: Codable, Equatable, Identifiable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let displayName: String
    public let author: String
    public let source: ThemeSource
    public let variants: [ThemeVariant]

    public init(
        schemaVersion: Int,
        id: String,
        displayName: String,
        author: String,
        source: ThemeSource,
        variants: [ThemeVariant]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.author = author
        self.source = source
        self.variants = variants.map { $0.with(packID: id) }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let id = try container.decode(String.self, forKey: .id)

        self.init(
            schemaVersion: schemaVersion,
            id: id,
            displayName: try container.decode(String.self, forKey: .displayName),
            author: try container.decode(String.self, forKey: .author),
            source: try container.decode(ThemeSource.self, forKey: .source),
            variants: try container.decode([ThemeVariant].self, forKey: .variants)
        )
    }
}

/// Provenance for a Theme Pack.
public struct ThemeSource: Codable, Equatable, Sendable {
    public let type: ThemeSourceType
    public let url: URL
    public let revision: String
    public let license: String
    public let attribution: String

    public init(type: ThemeSourceType, url: URL, revision: String, license: String, attribution: String) {
        self.type = type
        self.url = url
        self.revision = revision
        self.license = license
        self.attribution = attribution
    }
}

public enum ThemeSourceType: String, Codable, Equatable, Sendable {
    case generated
    case upstream
}

/// A concrete light or dark expression of a Theme Pack.
public struct ThemeVariant: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let appearance: ThemeAppearance
    public let contentDigest: String
    public let roles: [SemanticRole: ThemeColor]
    public let wallpaper: ThemeWallpaper?
    public private(set) var qualifiedID: String

    public init(
        id: String,
        displayName: String,
        appearance: ThemeAppearance,
        contentDigest: String,
        roles: [SemanticRole: ThemeColor],
        wallpaper: ThemeWallpaper? = nil,
        packID: String = ""
    ) {
        self.id = id
        self.displayName = displayName
        self.appearance = appearance
        self.contentDigest = contentDigest
        self.roles = roles
        self.wallpaper = wallpaper
        qualifiedID = packID.isEmpty ? id : "\(packID)/\(id)"
    }

    public func with(packID: String) -> ThemeVariant {
        ThemeVariant(
            id: id,
            displayName: displayName,
            appearance: appearance,
            contentDigest: contentDigest,
            roles: roles,
            wallpaper: wallpaper,
            packID: packID
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, appearance, contentDigest, roles, wallpaper
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            displayName: try container.decode(String.self, forKey: .displayName),
            appearance: try container.decode(ThemeAppearance.self, forKey: .appearance),
            contentDigest: try container.decode(String.self, forKey: .contentDigest),
            roles: try container.decode(RoleMap.self, forKey: .roles).values,
            wallpaper: try container.decodeIfPresent(ThemeWallpaper.self, forKey: .wallpaper)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(contentDigest, forKey: .contentDigest)
        try container.encode(RoleMap(values: roles), forKey: .roles)
        try container.encodeIfPresent(wallpaper, forKey: .wallpaper)
    }
}

public enum ThemeAppearance: String, Codable, Equatable, Sendable {
    case dark
    case light
}

/// A target-independent role in a Theme Variant.
public enum SemanticRole: String, CaseIterable, Codable, Sendable {
    case accent
    case ansiBlack = "ansi-black"
    case ansiBlue = "ansi-blue"
    case ansiCyan = "ansi-cyan"
    case ansiGreen = "ansi-green"
    case ansiMagenta = "ansi-magenta"
    case ansiRed = "ansi-red"
    case ansiWhite = "ansi-white"
    case ansiYellow = "ansi-yellow"
    case canvas
    case overlay
    case primaryText = "primary-text"
    case secondaryText = "secondary-text"
    case selection
    case surface
    case syntaxComment = "syntax-comment"
    case syntaxKeyword = "syntax-keyword"
    case syntaxString = "syntax-string"

}

/// A normalized device-independent sRGB value represented as `#rrggbb`.
public struct ThemeColor: Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ThemeWallpaper: Codable, Equatable, Sendable {
    public let assetPath: String
    public let contentDigest: String
    public let attribution: String

    public init(assetPath: String, contentDigest: String, attribution: String) {
        self.assetPath = assetPath
        self.contentDigest = contentDigest
        self.attribution = attribution
    }
}

private struct RoleMap: Codable {
    let values: [SemanticRole: ThemeColor]

    init(values: [SemanticRole: ThemeColor]) {
        self.values = values
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: StringKey.self)
        var values: [SemanticRole: ThemeColor] = [:]

        for key in container.allKeys {
            guard let role = SemanticRole(rawValue: key.stringValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "Unknown semantic role '\(key.stringValue)'."
                )
            }
            values[role] = try container.decode(ThemeColor.self, forKey: key)
        }

        self.values = values
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: StringKey.self)
        for role in SemanticRole.allCases {
            if let color = values[role] {
                try container.encode(color, forKey: StringKey(role.rawValue))
            }
        }
    }
}

private struct StringKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue _: Int) {
        nil
    }
}
