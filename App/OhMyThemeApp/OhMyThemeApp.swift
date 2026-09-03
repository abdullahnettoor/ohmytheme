import SwiftUI

@main
struct OhMyThemeApp: App {
    @State private var isMenuBarItemInserted = true
    @StateObject private var menuModel: WorkspaceMenuModel

    init() {
        let runtime = ProductionWorkspaceRuntime()
        _menuModel = StateObject(wrappedValue: WorkspaceMenuModel(runtime: runtime))
        MenuBarPresence.clearHiddenStatusItemPreferences(in: UserDefaults.standard)
    }

    var body: some Scene {
        MenuBarExtra(
            "Oh My Theme",
            systemImage: "paintpalette",
            isInserted: $isMenuBarItemInserted
        ) {
            WorkspaceMenuView(model: menuModel)
                .task {
                    await menuModel.start()
                }
        }
        .menuBarExtraStyle(.window)
    }
}
