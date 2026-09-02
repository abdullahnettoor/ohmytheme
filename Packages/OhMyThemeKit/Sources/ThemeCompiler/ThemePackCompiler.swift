import CryptoKit
import Foundation
import ThemeModel

/// Decodes and validates data-only Theme Packs for the app and maintainer tools.
public struct ThemePackCompiler: Sendable {
    public static let supportedSchemaVersion = 1

    public init() {}

    public func decodePack(_ data: Data, baseDirectory: URL? = nil) throws -> ThemePack {
        let pack: ThemePack
        do {
            try validateJSONShape(data)
            pack = try JSONDecoder().decode(ThemePack.self, from: data)
        } catch let error as ThemePackValidationError {
            throw error
        } catch {
            throw ThemePackValidationError.invalidJSON
        }
        try validate(pack, baseDirectory: baseDirectory)
        return pack
    }

    public func loadPack(at fileURL: URL) throws -> ThemePack {
        do {
            return try decodePack(Data(contentsOf: fileURL), baseDirectory: fileURL.deletingLastPathComponent())
        } catch let error as ThemePackValidationError {
            throw error
        } catch {
            throw ThemePackValidationError.unreadablePack(fileURL.path)
        }
    }

    public func loadPacks(at directoryURL: URL) throws -> [ThemePack] {
        let fileURLs: [URL]
        do {
            fileURLs = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ThemePackValidationError.unreadablePack(directoryURL.path)
        }

        let packs =
            try fileURLs
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(loadPack)
            .sorted { $0.id < $1.id }
        try validateCollection(packs)
        return packs
    }

    public func renderCatalog(for packs: [ThemePack]) throws -> Data {
        try validateCatalog(packs)
        let entries = packs.flatMap { pack in
            pack.variants.map {
                ThemeCatalogEntry(
                    qualifiedID: $0.qualifiedID,
                    packID: pack.id,
                    packDisplayName: pack.displayName,
                    variantID: $0.id,
                    displayName: $0.displayName,
                    appearance: $0.appearance,
                    sourceType: pack.source.type,
                    sourceRevision: pack.source.revision,
                    attribution: pack.source.attribution
                )
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            ThemeCatalog(
                schemaVersion: Self.supportedSchemaVersion,
                variants: entries.sorted {
                    $0.qualifiedID < $1.qualifiedID
                }))
    }

    public func contentDigest(for variant: ThemeVariant) throws -> String {
        let content = VariantContent(
            id: variant.id,
            displayName: variant.displayName,
            appearance: variant.appearance,
            roles: variant.roles
                .map { RoleEntry(role: $0.key.rawValue, color: $0.value.rawValue) }
                .sorted(using: KeyPathComparator(\.role)),
            wallpaper: variant.wallpaper
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(content)
        return "sha256:\(SHA256.hash(data: data).hexadecimalString)"
    }

    public func validateCatalog(_ packs: [ThemePack]) throws {
        try validateCollection(packs)
    }

    private func validate(_ pack: ThemePack, baseDirectory: URL?) throws {
        guard pack.schemaVersion == Self.supportedSchemaVersion else {
            throw ThemePackValidationError.unsupportedSchema(pack.schemaVersion)
        }
        try validateIdentifier(pack.id)
        try validateMetadata(pack)
        guard !pack.variants.isEmpty else {
            throw ThemePackValidationError.emptyVariants(pack.id)
        }

        var identifiers = Set<String>()
        for variant in pack.variants {
            guard identifiers.insert(variant.id).inserted else {
                throw ThemePackValidationError.duplicateVariantIdentifier(variant.id)
            }
            try validateIdentifier(variant.id)
            guard Set(variant.roles.keys) == Set(SemanticRole.allCases) else {
                let missing = Set(SemanticRole.allCases).subtracting(variant.roles.keys)
                    .map(\.rawValue)
                    .sorted()
                throw ThemePackValidationError.missingSemanticRoles(missing)
            }
            for color in variant.roles.values {
                try validate(color)
            }
            if let wallpaper = variant.wallpaper {
                try validate(wallpaper, relativeTo: baseDirectory)
            }
            guard try contentDigest(for: variant) == variant.contentDigest else {
                throw ThemePackValidationError.contentDigestMismatch(variant.qualifiedID)
            }
        }
    }

    private func validateMetadata(_ pack: ThemePack) throws {
        guard let sourceHost = pack.source.url.host,
            !pack.displayName.isEmpty,
            !pack.author.isEmpty,
            !pack.source.revision.isEmpty,
            !pack.source.license.isEmpty,
            !pack.source.attribution.isEmpty,
            pack.source.url.scheme == "https",
            !sourceHost.isEmpty
        else {
            throw ThemePackValidationError.inconsistentMetadata(pack.id)
        }
    }

    private func validateJSONShape(_ data: Data) throws {
        let root: [String: Any]
        do {
            root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            throw ThemePackValidationError.invalidJSON
        }
        guard !root.isEmpty else {
            throw ThemePackValidationError.invalidJSON
        }

        try validateKeys(
            root,
            allowed: ["schemaVersion", "id", "displayName", "author", "source", "variants"]
        )
        if let source = root["source"] as? [String: Any] {
            try validateKeys(
                source,
                allowed: ["type", "url", "revision", "license", "attribution"]
            )
        }
        if let variants = root["variants"] as? [Any] {
            for variant in variants {
                guard let variant = variant as? [String: Any] else { continue }
                try validateKeys(
                    variant,
                    allowed: ["id", "displayName", "appearance", "contentDigest", "roles", "wallpaper"]
                )
                if let wallpaper = variant["wallpaper"] {
                    guard let wallpaper = wallpaper as? [String: Any] else {
                        throw ThemePackValidationError.invalidJSON
                    }
                    try validateKeys(
                        wallpaper,
                        allowed: ["assetPath", "contentDigest", "attribution"]
                    )
                }
            }
        }
    }

    private func validateKeys(_ object: [String: Any], allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else {
            throw ThemePackValidationError.invalidJSON
        }
    }

    private func validateCollection(_ packs: [ThemePack]) throws {
        var packIdentifiers = Set<String>()
        var variantIdentifiers = Set<String>()

        for pack in packs {
            guard packIdentifiers.insert(pack.id).inserted else {
                throw ThemePackValidationError.duplicatePackIdentifier(pack.id)
            }
            for variant in pack.variants {
                guard variantIdentifiers.insert(variant.qualifiedID).inserted else {
                    throw ThemePackValidationError.duplicateVariantIdentifier(variant.qualifiedID)
                }
            }
        }
    }

    private func validateIdentifier(_ identifier: String) throws {
        guard identifier.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil
        else {
            throw ThemePackValidationError.invalidIdentifier(identifier)
        }
    }

    private func validate(_ color: ThemeColor) throws {
        if color.rawValue.range(of: #"^#[0-9a-f]{8}$"#, options: .regularExpression) != nil {
            throw ThemePackValidationError.forbiddenAlpha(color.rawValue)
        }
        guard color.rawValue.range(of: #"^#[0-9a-f]{6}$"#, options: .regularExpression) != nil else {
            throw ThemePackValidationError.malformedColor(color.rawValue)
        }
    }

    private func validate(_ wallpaper: ThemeWallpaper, relativeTo baseDirectory: URL?) throws {
        let path = wallpaper.assetPath
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw ThemePackValidationError.unsafeAssetPath(path)
        }
        guard let baseDirectory else { return }
        let resolvedBaseDirectory = baseDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let assetURL = baseDirectory.appending(path: path).standardizedFileURL.resolvingSymlinksInPath()
        guard assetURL.path.hasPrefix(resolvedBaseDirectory.path + "/") else {
            throw ThemePackValidationError.unsafeAssetPath(path)
        }
        guard let data = try? Data(contentsOf: assetURL) else {
            throw ThemePackValidationError.assetDigestMismatch(path)
        }
        let digest = "sha256:\(SHA256.hash(data: data).hexadecimalString)"
        guard digest == wallpaper.contentDigest else {
            throw ThemePackValidationError.assetDigestMismatch(path)
        }
    }
}

public enum ThemePackValidationError: Error, Equatable, LocalizedError, Sendable {
    case assetDigestMismatch(String)
    case contentDigestMismatch(String)
    case duplicatePackIdentifier(String)
    case duplicateVariantIdentifier(String)
    case emptyVariants(String)
    case forbiddenAlpha(String)
    case inconsistentMetadata(String)
    case invalidIdentifier(String)
    case invalidJSON
    case malformedColor(String)
    case missingSemanticRoles([String])
    case unreadablePack(String)
    case unsafeAssetPath(String)
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .assetDigestMismatch(let path): "Asset digest mismatch: \(path)."
        case .contentDigestMismatch(let identifier): "Content digest mismatch: \(identifier)."
        case .duplicatePackIdentifier(let identifier): "Duplicate Theme Pack identifier: \(identifier)."
        case .duplicateVariantIdentifier(let identifier): "Duplicate Theme Variant identifier: \(identifier)."
        case .emptyVariants(let identifier): "Theme Pack has no Theme Variants: \(identifier)."
        case .forbiddenAlpha(let color): "Alpha is forbidden for this semantic role: \(color)."
        case .inconsistentMetadata(let identifier): "Inconsistent metadata in Theme Pack: \(identifier)."
        case .invalidIdentifier(let identifier): "Invalid identifier: \(identifier)."
        case .invalidJSON: "Theme Pack JSON is invalid."
        case .malformedColor(let color): "Malformed color: \(color)."
        case .missingSemanticRoles(let roles): "Missing semantic roles: \(roles.joined(separator: ", "))."
        case .unreadablePack(let path): "Theme Pack cannot be read: \(path)."
        case .unsafeAssetPath(let path): "Unsafe asset path: \(path)."
        case .unsupportedSchema(let version): "Unsupported Theme Pack schema version: \(version)."
        }
    }
}

private struct VariantContent: Encodable {
    let id: String
    let displayName: String
    let appearance: ThemeAppearance
    let roles: [RoleEntry]
    let wallpaper: ThemeWallpaper?
}

private struct ThemeCatalog: Encodable {
    let schemaVersion: Int
    let variants: [ThemeCatalogEntry]
}

private struct ThemeCatalogEntry: Encodable {
    let qualifiedID: String
    let packID: String
    let packDisplayName: String
    let variantID: String
    let displayName: String
    let appearance: ThemeAppearance
    let sourceType: ThemeSourceType
    let sourceRevision: String
    let attribution: String
}

private struct RoleEntry: Encodable {
    let role: String
    let color: String
}

private extension Digest {
    var hexadecimalString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
