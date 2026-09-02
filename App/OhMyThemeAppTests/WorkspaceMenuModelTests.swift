import Foundation
import ThemeEngine
import ThemeModel
import XCTest

@testable import OhMyTheme

/// Smoke tests for what the menu-bar window presents and offers.
@MainActor
final class WorkspaceMenuModelTests: XCTestCase {
    func testMenuPresentsTheMyMacWorkspace() {
        let model = WorkspaceMenuModel(workspace: WorkspaceStore().workspace, quitAction: {})

        XCTAssertEqual(model.workspaceName, "My Mac")
    }

    func testMenuExplainsThatNothingIsConnectedYet() throws {
        let model = WorkspaceMenuModel(workspace: WorkspaceStore().workspace, quitAction: {})

        let message = try XCTUnwrap(model.emptyStateMessage)
        XCTAssertTrue(message.contains("No apps are connected yet"))
        XCTAssertTrue(model.connectedTargetInstanceNames.isEmpty)
    }

    func testMenuListsConnectedTargetInstancesInsteadOfTheEmptyState() {
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "ghostty.default"),
                    displayName: "Ghostty",
                    adapterID: "recording"
                ),
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "vscode.default"),
                    displayName: "Visual Studio Code",
                    adapterID: "recording"
                ),
            ]
        )

        let model = WorkspaceMenuModel(workspace: workspace, quitAction: {})

        XCTAssertNil(model.emptyStateMessage)
        XCTAssertEqual(model.connectedTargetInstanceNames, ["Ghostty", "Visual Studio Code"])
    }

    func testMenuListsBundledThemeVariantsWithProvenance() {
        let model = WorkspaceMenuModel(workspace: WorkspaceStore().workspace)

        XCTAssertEqual(
            model.bundledThemeVariants.map(\.name),
            ["Catppuccin Mocha", "Oh My Theme Aurora"]
        )
        XCTAssertEqual(model.bundledThemeVariants.map(\.sourceType), ["upstream", "generated"])
        XCTAssertTrue(model.bundledThemeVariants.allSatisfy { !$0.sourceRevision.isEmpty && !$0.attribution.isEmpty })
    }

    func testMenuRequestsPreviewThroughThemeEngine() async throws {
        let workspace = Workspace(
            id: .myMac,
            displayName: "My Mac",
            connectedTargetInstances: [
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "recording.preview"),
                    displayName: "Recording Target",
                    adapterID: "recording"
                )
            ]
        )
        let pack = try XCTUnwrap(BundledThemeCatalog().load().first)
        let engine = ThemeEngine(packs: [pack], adapters: [RecordingThemeAdapter()])
        let model = WorkspaceMenuModel(
            workspace: workspace,
            themePacks: [pack],
            themeEngine: engine,
            quitAction: {}
        )

        let preview = try await model.prepare(themeVariantID: pack.variants[0].qualifiedID)

        XCTAssertEqual(preview.targetPlans.count, 1)
        XCTAssertEqual(preview.variantID, pack.variants[0].qualifiedID)
    }

    func testQuitAsksTheApplicationToTerminate() {
        var terminationRequests = 0
        let model = WorkspaceMenuModel(workspace: WorkspaceStore().workspace, quitAction: { terminationRequests += 1 })

        model.quit()

        XCTAssertEqual(terminationRequests, 1)
    }
}
