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
                ConnectedTargetInstance(id: TargetInstanceID(rawValue: "ghostty.default"), displayName: "Ghostty"),
                ConnectedTargetInstance(
                    id: TargetInstanceID(rawValue: "vscode.default"), displayName: "Visual Studio Code"),
            ]
        )

        let model = WorkspaceMenuModel(workspace: workspace, quitAction: {})

        XCTAssertNil(model.emptyStateMessage)
        XCTAssertEqual(model.connectedTargetInstanceNames, ["Ghostty", "Visual Studio Code"])
    }

    func testQuitAsksTheApplicationToTerminate() {
        var terminationRequests = 0
        let model = WorkspaceMenuModel(workspace: WorkspaceStore().workspace, quitAction: { terminationRequests += 1 })

        model.quit()

        XCTAssertEqual(terminationRequests, 1)
    }
}
