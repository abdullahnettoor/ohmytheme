import SwiftUI
import ThemeEngine
import ThemeModel

@main
struct OhMyThemeApp: App {
    /// Insertion state is deliberately launch-scoped and never persisted, so an ordinary
    /// relaunch restores the menu-bar presence even when the previous run ended with the
    /// item removed from the menu bar.
    @State private var isMenuBarItemInserted = true

    private let workspaceStore = WorkspaceStore()
    private let themeEngine: ThemeEngine

    init() {
        themeEngine = ThemeEngine(
            packs: BundledThemeCatalog().load(),
            adapters: [RecordingThemeAdapter()]
        )
        MenuBarPresence.clearHiddenStatusItemPreferences(in: UserDefaults.standard)
    }

    var body: some Scene {
        MenuBarExtra(
            "Oh My Theme",
            systemImage: "paintpalette",
            isInserted: $isMenuBarItemInserted
        ) {
            WorkspaceMenuView(
                model: WorkspaceMenuModel(
                    workspace: workspaceStore.appWorkspace,
                    themeEngine: themeEngine,
                    themeVariantSelection: { variantID in
                        workspaceStore.selectFixedVariant(variantID)
                    }
                ))
        }
        .menuBarExtraStyle(.window)
    }
}
