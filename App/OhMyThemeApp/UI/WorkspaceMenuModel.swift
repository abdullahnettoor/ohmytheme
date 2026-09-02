import AppKit
import ThemeModel

/// Presentation state for the menu-bar window.
///
/// It exposes what the menu shows and the actions it offers, without owning any theme,
/// target, or file behavior.
@MainActor
struct WorkspaceMenuModel {
    private let workspace: Workspace
    private let quitAction: @MainActor () -> Void

    init(
        workspace: Workspace,
        quitAction: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.workspace = workspace
        self.quitAction = quitAction
    }

    var workspaceName: String {
        workspace.displayName
    }

    /// The Connected Target Instances the menu lists, in the order the Workspace holds them.
    var connectedTargetInstanceNames: [String] {
        workspace.connectedTargetInstances.map(\.displayName)
    }

    /// The explanation shown while the Workspace manages nothing, or `nil` once at least
    /// one Target Instance is connected.
    var emptyStateMessage: String? {
        guard workspace.connectedTargetInstances.isEmpty else { return nil }
        return "No apps are connected yet. Oh My Theme changes nothing until you connect an app to My Mac."
    }

    func quit() {
        quitAction()
    }
}
