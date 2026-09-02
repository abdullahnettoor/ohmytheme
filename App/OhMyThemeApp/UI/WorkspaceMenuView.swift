import SwiftUI

/// The menu-bar window: the Workspace, what it currently manages, and Quit.
struct WorkspaceMenuView: View {
    let model: WorkspaceMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.workspaceName)
                    .font(.headline)
                Text("Workspace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let emptyStateMessage = model.emptyStateMessage {
                Text(emptyStateMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("workspace-empty-state")
            } else {
                ForEach(model.connectedTargetInstanceNames, id: \.self) { name in
                    Text(name)
                        .font(.callout)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Bundled themes")
                    .font(.headline)
                ForEach(model.bundledThemeVariants, id: \.name) { variant in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(variant.name)
                        Text("\(variant.appearance) · \(variant.sourceType) · \(variant.sourceRevision)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(variant.attribution)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("bundled-theme-\(variant.name)")
                }
            }

            Divider()

            Button("Quit Oh My Theme") {
                model.quit()
            }
            .keyboardShortcut("q")
            .accessibilityIdentifier("quit-oh-my-theme")
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }
}

#Preview {
    WorkspaceMenuView(model: WorkspaceMenuModel(workspace: WorkspaceStore().workspace, quitAction: {}))
}
