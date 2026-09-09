import PlatformClients
import SwiftUI

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

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let presenceController else { return }
        presenceController.refreshLaunchAtLoginStatus()
        Task {
            await presenceController.refreshNotificationPermissionStatus()
        }
    }
}

@main
struct OhMyThemeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var presenceController: AppPresenceController
    @StateObject private var workspaceModel: WorkspacePresentationModel
    private let platform: ProductionAppPresencePlatform

    init() {
        let runtime = ProductionWorkspaceRuntime()
        let workspaceModel = WorkspacePresentationModel(runtime: runtime)
        _workspaceModel = StateObject(wrappedValue: workspaceModel)

        let platform = ProductionAppPresencePlatform()
        self.platform = platform
        let launchClient = LaunchAtLoginClient()
        let notificationClient = ProductionNotificationClient()
        let controller = AppPresenceController(
            platform: platform,
            launchAtLoginPlatform: launchClient,
            notificationClient: notificationClient,
            defaults: UserDefaults.standard,
            runtime: runtime
        )
        controller.presentationModel = workspaceModel
        workspaceModel.presenceController = controller
        _presenceController = StateObject(wrappedValue: controller)
        AppDelegate.shared?.presenceController = controller
    }

    var body: some Scene {
        Window("Oh My Theme", id: "main") {
            MainWindowView(
                presenceController: presenceController,
                model: workspaceModel
            )
            .background(WindowBridge(platform: platform))
            .task {
                await workspaceModel.start()
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

private struct WindowBridge: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow
    let platform: ProductionAppPresencePlatform

    func makeNSView(context: Context) -> MainWindowTrackingView {
        configureOpenWindowAction()
        return MainWindowTrackingView { window in
            platform.setMainWindow(window)
        }
    }

    func updateNSView(_ nsView: MainWindowTrackingView, context: Context) {
        configureOpenWindowAction()
    }

    private func configureOpenWindowAction() {
        platform.setOpenWindowAction {
            openWindow(id: "main")
        }
    }
}

private final class MainWindowTrackingView: NSView {
    private let windowDidChange: (NSWindow?) -> Void

    init(windowDidChange: @escaping (NSWindow?) -> Void) {
        self.windowDidChange = windowDidChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowDidChange(window)
    }
}
