import SwiftUI
import ThemeEngine

/// The menu-bar window: the Workspace, what it currently manages, and Quit.
struct WorkspaceMenuView: View {
    let model: WorkspaceMenuModel
    @State private var selectedVariantID: String?
    @State private var preview: ThemePreview?
    @State private var report: ApplyReport?
    @State private var operationError: String?

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

            if model.canApplyThemes {
                Picker("Theme Variant", selection: $selectedVariantID) {
                    Text("Choose a Theme Variant").tag(nil as String?)
                    ForEach(model.bundledThemeVariants, id: \.variantID) { variant in
                        Text(variant.name).tag(variant.variantID as String?)
                    }
                }
                .accessibilityIdentifier("theme-variant-picker")

                Button("Preview selected Theme Variant") {
                    guard let selectedVariantID else { return }
                    Task {
                        do {
                            preview = try await model.prepare(themeVariantID: selectedVariantID)
                            report = nil
                            operationError = nil
                        } catch {
                            operationError = String(describing: error)
                        }
                    }
                }
                .disabled(selectedVariantID == nil)

                if let preview {
                    Text("\(preview.sourceType.rawValue) · \(preview.sourceRevision)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Activation: \(preview.activationReach.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(preview.setupNeeds, id: \.title) { action in
                        Text("\(action.title): \(action.detail)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Apply preview") {
                        Task {
                            do {
                                report = try await model.apply(previewID: preview.id)
                                operationError = nil
                            } catch {
                                operationError = String(describing: error)
                            }
                        }
                    }
                    .disabled(preview.targetPlans.isEmpty)
                }

                if let report {
                    Text("Applied to \(report.outcomes.count) Target Instance\(report.outcomes.count == 1 ? "" : "s").")
                        .font(.caption)
                        .accessibilityIdentifier("theme-apply-report")
                }
                if let operationError {
                    Text(operationError)
                        .font(.caption)
                        .foregroundStyle(.red)
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
