import SwiftUI

@main
struct OhMyThemeApp: App {
    /// Insertion state is deliberately launch-scoped and never persisted, so an ordinary
    /// relaunch restores the menu-bar presence even when the previous run ended with the
    /// item removed from the menu bar.
    @State private var isMenuBarItemInserted = true

    private let workspaceStore = WorkspaceStore()

    init() {
        MenuBarPresence.clearHiddenStatusItemPreferences(in: UserDefaults.standard)
    }

    var body: some Scene {
        MenuBarExtra(
            "Oh My Theme",
            systemImage: "paintpalette",
            isInserted: $isMenuBarItemInserted
        ) {
            WorkspaceMenuView(model: WorkspaceMenuModel(workspace: workspaceStore.workspace))
        }
        .menuBarExtraStyle(.window)
    }
}
