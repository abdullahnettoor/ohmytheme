import SwiftUI
import ThemeEngine
import ThemeModel

struct OverviewView: View {
    @ObservedObject var model: WorkspaceMenuModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack(spacing: 16) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 32))
                        .foregroundStyle(.tint)
                        .frame(width: 48, height: 48)
                        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.workspaceName)
                            .font(.title2.weight(.bold))
                        Text("One theme for your connected workspace")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.bottom, 8)

                // Workspace Status Card
                VStack(alignment: .leading, spacing: 12) {
                    Text("Workspace Status")
                        .font(.headline)

                    HStack(spacing: 20) {
                        statusBadge(
                            title: "Connected Apps",
                            value: "\(model.workspace.connectedTargetInstances.count)",
                            systemImage: "app.badge"
                        )
                        statusBadge(
                            title: "Selected Theme",
                            value: model.selectedThemeVariantID ?? "None",
                            systemImage: "paintpalette"
                        )
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                if let plan = model.applyPlan {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Apply Plan")
                            .font(.headline)
                        Text(plan.variantID)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let report = model.report {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Latest Apply Report")
                            .font(.headline)
                        Text(report.title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let emptyStateMessage = model.emptyStateMessage, model.applicationTargets.isEmpty {
                    Text(emptyStateMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }

                if let error = model.persistenceError ?? model.operationError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    .padding()
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(24)
        }
        .navigationTitle("Overview")
    }

    private func statusBadge(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body.weight(.medium))
            }
        }
    }
}
