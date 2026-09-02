import Foundation
import ThemeCompiler
import ThemeModel

/// Loads only Theme Packs shipped inside the app bundle.
struct BundledThemeCatalog {
    private static let packFileNames = ["catppuccin-mocha", "oh-my-theme-aurora"]

    func load() -> [ThemePack] {
        let compiler = ThemePackCompiler()
        return Self.packFileNames.compactMap { fileName in
            guard let url = Bundle.main.url(forResource: fileName, withExtension: "json") else {
                return nil
            }
            return try? compiler.loadPack(at: url)
        }
    }
}
