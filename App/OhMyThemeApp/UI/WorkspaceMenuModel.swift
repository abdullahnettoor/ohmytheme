import AppKit
import ThemeEngine
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
    private let themeEngine: ThemeEngine?

    init(
        workspace: Workspace,
        themePacks: [ThemePack] = BundledThemeCatalog().load(),
        themeEngine: ThemeEngine? = nil,
        quitAction: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    ) {
        self.workspace = workspace
        self.themePacks = themePacks
        self.themeEngine = themeEngine
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
                    variantID: $0.qualifiedID,
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

    func prepare(themeVariantID: String) async throws -> ThemePreview {
        guard let themeEngine else {
            throw ThemeEngineError.engineUnavailable
        }
        return try await themeEngine.prepare(themeVariantID: themeVariantID, workspace: workspace)
    }

    func apply(previewID: UUID) async throws -> ApplyReport {
        guard let themeEngine else {
            throw ThemeEngineError.engineUnavailable
        }
        return try await themeEngine.apply(previewID: previewID)
    }

    var canApplyThemes: Bool {
        themeEngine != nil
    }

    struct BundledThemeVariant: Equatable {
        let name: String
        let variantID: String
        let appearance: String
        let sourceType: String
        let sourceRevision: String
        let attribution: String
    }
}
