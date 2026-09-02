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
    private let themePacks: [ThemePack]

    init(
        workspace: Workspace,
        themePacks: [ThemePack] = BundledThemeCatalog().load(),
        quitAction: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.workspace = workspace
        self.themePacks = themePacks
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

    var bundledThemeVariants: [BundledThemeVariant] {
        themePacks.flatMap { pack in
            pack.variants.map {
                BundledThemeVariant(
                    name: "\(pack.displayName) \($0.displayName)",
                    appearance: $0.appearance.rawValue,
                    sourceType: pack.source.type.rawValue,
                    sourceRevision: pack.source.revision,
                    attribution: pack.source.attribution
                )
            }
        }
    }

    func quit() {
        quitAction()
    }

    struct BundledThemeVariant: Equatable {
        let name: String
        let appearance: String
        let sourceType: String
        let sourceRevision: String
        let attribution: String
    }
}
