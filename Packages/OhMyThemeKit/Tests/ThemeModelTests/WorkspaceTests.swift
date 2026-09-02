import Testing

@testable import ThemeModel

@Suite("My Mac Workspace")
struct WorkspaceTests {
    @Test("The first-run Workspace is named My Mac")
    func firstRunWorkspaceIsNamedMyMac() {
        #expect(Workspace.myMac.displayName == "My Mac")
    }

    @Test("The first-run Workspace keeps a stable identifier across launches")
    func firstRunWorkspaceHasStableIdentifier() {
        #expect(Workspace.myMac.id.rawValue == "my-mac")
    }

    @Test("The first-run Workspace has connected no Target Instances")
    func firstRunWorkspaceHasNothingConnected() {
        #expect(Workspace.myMac.connectedTargetInstances.isEmpty)
    }
}
