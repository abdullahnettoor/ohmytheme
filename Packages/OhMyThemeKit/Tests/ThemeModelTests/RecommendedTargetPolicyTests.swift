import Testing
@testable import ThemeModel

@Suite("Recommended Target Policy")
struct RecommendedTargetPolicyTests {
    @Test("Stable allowlist includes macOS appearance and wallpaper")
    func allowlistIncludesMacOSAdapters() {
        #expect(RecommendedTargetPolicy.isAllowlisted(adapterID: "macos.appearance"))
        #expect(RecommendedTargetPolicy.isAllowlisted(adapterID: "macos.wallpaper"))
        #expect(RecommendedTargetPolicy.isAllowlisted(adapterID: "ghostty"))
        #expect(RecommendedTargetPolicy.isAllowlisted(adapterID: "vscode"))
        #expect(RecommendedTargetPolicy.isAllowlisted(adapterID: "starship"))
        #expect(!RecommendedTargetPolicy.isAllowlisted(adapterID: "unknown_adapter"))
    }

    @Test("Wallpaper display is recommended when available and theme contains wallpaper")
    func wallpaperRecommendedWhenAvailableAndThemeHasWallpaper() {
        let result = RecommendedTargetPolicy.evaluateWallpaperDisplay(
            isAvailable: true,
            themeContainsWallpaper: true
        )
        #expect(result.isRecommended)
        #expect(result.exclusionReason == nil)
        #expect(result.exclusionDetail == nil)
    }

    @Test("Wallpaper display is excluded when theme has no wallpaper")
    func wallpaperExcludedWhenThemeHasNoWallpaper() {
        let result = RecommendedTargetPolicy.evaluateWallpaperDisplay(
            isAvailable: true,
            themeContainsWallpaper: false
        )
        #expect(!result.isRecommended)
        #expect(result.exclusionReason == .unavailable)
        #expect(result.exclusionDetail == "The selected theme does not contain a wallpaper.")
    }

    @Test("Wallpaper display is excluded when display is unavailable even if theme has wallpaper")
    func wallpaperExcludedWhenDisplayUnavailable() {
        let result = RecommendedTargetPolicy.evaluateWallpaperDisplay(
            isAvailable: false,
            themeContainsWallpaper: true
        )
        #expect(!result.isRecommended)
        #expect(result.exclusionReason == .unavailable)
        #expect(result.exclusionDetail == "Display is unavailable.")
    }
}
