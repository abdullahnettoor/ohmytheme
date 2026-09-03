import Foundation
import ThemeCompiler
import ThemeModel

/// Loads only Theme Packs shipped inside the app bundle.
struct BundledThemeCatalog {
    private static let packFileNames = ["catppuccin-mocha", "oh-my-theme-aurora"]

    func load() throws -> [ThemePack] {
        let compiler = ThemePackCompiler()
        let packs = try Self.packFileNames.map { fileName in
            guard let url = Bundle.main.url(forResource: fileName, withExtension: "json") else {
                throw BundledThemeCatalogError.missingResource(fileName)
            }
            return try compiler.loadPack(at: url)
        }
        try compiler.validateCatalog(packs)
        return packs
    }
}

enum BundledThemeCatalogError: Error, Equatable {
    case missingResource(String)
}
