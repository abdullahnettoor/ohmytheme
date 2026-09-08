import SwiftUI
import ThemeModel

struct AppsView: View {
    @ObservedObject var model: WorkspaceMenuModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apps")
                        .font(.title2.weight(.bold))
                    Text("Manage connected and discovered applications on this Mac.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if model.applicationTargets.isEmpty {
                    Text(model.emptyStateMessage ?? "No targets discovered.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(model.applicationTargets, id: \.id) { app in
                            HStack {
                                Image(systemName: app.systemImage)
                                    .font(.title2)
                                    .frame(width: 32, height: 32)
                                    .foregroundStyle(.tint)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name)
                                        .font(.headline)
                                    Text(app.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text(app.state.rawValue)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                            .padding()
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Apps")
    }
}
