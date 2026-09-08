import SwiftUI

struct OverviewView: View {
    @ObservedObject var model: WorkspacePresentationModel

    var body: some View {
        WorkspaceControlsView(model: model)
            .navigationTitle("Overview")
    }
}
