import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var presenceController: AppPresenceController

    var body: some View {
        Text(presenceController.workspaceHealth)
            .accessibilityIdentifier("menu-workspace-health")
        Divider()
        Button("Open Oh My Theme") {
            presenceController.openMainWindow()
        }
        .keyboardShortcut("o")
        .accessibilityIdentifier("menu-open-main-window")
        Divider()
        Button("Quit Oh My Theme") {
            presenceController.quitApp()
        }
        .keyboardShortcut("q")
        .accessibilityIdentifier("menu-quit")
    }
}
