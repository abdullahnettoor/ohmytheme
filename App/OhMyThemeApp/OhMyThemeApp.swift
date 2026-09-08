import SwiftUI
import PlatformClients

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    weak var presenceController: AppPresenceController?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presenceController?.handleReopen(hasVisibleWindows: flag) ?? true
    }
}

@main
struct OhMyThemeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var presenceController: AppPresenceController
    @StateObject private var menuModel: WorkspaceMenuModel
    private let platform: ProductionAppPresencePlatform

    init() {
        let runtime = ProductionWorkspaceRuntime()
        let menuModel = WorkspaceMenuModel(runtime: runtime)
        _menuModel = StateObject(wrappedValue: menuModel)

        let platform = ProductionAppPresencePlatform()
        self.platform = platform
        let launchClient = LaunchAtLoginClient()
        let controller = AppPresenceController(
            platform: platform,
            launchAtLoginPlatform: launchClient,
            defaults: UserDefaults.standard,
            runtime: runtime
        )
        _presenceController = StateObject(wrappedValue: controller)
        AppDelegate.shared?.presenceController = controller
    }

    var body: some Scene {
        Window("Oh My Theme", id: "main") {
            MainWindowView(
                presenceController: presenceController,
                model: menuModel
            )
            .background(WindowBridge(platform: platform))
            .task {
                await menuModel.start()
            }
            .onAppear {
                appDelegate.presenceController = presenceController
            }
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(presenceController: presenceController)
        }

        MenuBarExtra(
            "Oh My Theme",
            systemImage: "paintpalette",
            isInserted: presenceController.isMenuBarVisibleBinding
        ) {
            MenuBarContentView(presenceController: presenceController)
        }
    }
}

private struct WindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    let platform: ProductionAppPresencePlatform

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                platform.setOpenWindowAction {
                    openWindow(id: "main")
                }
            }
    }
}
