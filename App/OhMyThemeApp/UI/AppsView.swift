import SwiftUI
import ThemeEngine
import ThemeModel

struct AppsView: View {
    @ObservedObject var model: WorkspacePresentationModel
    @State private var expandedApps: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if model.applicationTargets.isEmpty {
                    Text(model.emptyStateMessage ?? "No targets discovered.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("apps-empty-state")
                } else {
                    LazyVStack(spacing: 14) {
                        ForEach(model.applicationTargets, id: \.id) { app in
                            applicationGroupCard(app)
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Apps")
        .onAppear {
            if expandedApps.isEmpty {
                expandedApps = Set(model.applicationTargets.map(\.id))
            }
        }
        .task {
            model.perform {
                try await model.refreshTargets()
            }
        }
        .sheet(
            item: Binding(
                get: { model.setupPlan },
                set: { if $0 == nil { model.dismissSetupPlan() } }
            )
        ) { plan in
            SetupPlanReviewView(model: model, plan: plan)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apps")
                    .font(.title2.weight(.bold))
                Text("Manage apps and macOS capabilities that can join My Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                if model.hasUnresolvedOptedInTargets {
                    Button {
                        Task {
                            await model.prepareSetupPlan()
                        }
                    } label: {
                        Label("Review Setup Plan (\(model.unresolvedOptedInCount))", systemImage: "checklist")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || model.isPreparingSetupPlan)
                    .accessibilityIdentifier("review-setup-plan-button")
                }

                if model.canSelectAllRecommended {
                    Button {
                        model.perform {
                            try await model.selectAllRecommended()
                        }
                    } label: {
                        Label("Select All Recommended", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("select-all-recommended-button")
                } else if model.hasRecommendedTargets {
                    Label("All recommended selected", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.12), in: Capsule())
                        .accessibilityIdentifier("all-recommended-selected-badge")
                }
            }
        }
    }

    private func applicationGroupCard(_ app: WorkspacePresentationModel.ApplicationTarget) -> some View {
        let isExpanded = expandedApps.contains(app.id)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: app.systemImage)
                    .font(.title2)
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(app.name)
                            .font(.headline)
                        Text(app.state.rawValue)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(stateColor(app.state))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(stateColor(app.state).opacity(0.12), in: Capsule())

                        if app.state == .notSelected {
                            Text("Available")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }

                    Text(app.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                HStack(spacing: 10) {
                    if app.canSelectRecommended {
                        Button("Select Recommended") {
                            model.perform {
                                try await model.selectRecommended(for: app.id)
                            }
                        }
                        .controlSize(.small)
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("app-select-recommended-\(app.id)")
                    } else if app.allRecommendedOptedIn {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.green)
                    }

                    Button {
                        if isExpanded {
                            expandedApps.remove(app.id)
                        } else {
                            expandedApps.insert(app.id)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(app.instances.count)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("app-expand-button-\(app.id)")
                }
            }
            .padding(14)

            if isExpanded && !app.instances.isEmpty {
                Divider()
                    .padding(.horizontal, 14)

                VStack(spacing: 0) {
                    ForEach(Array(app.instances.enumerated()), id: \.element.id) { index, instance in
                        instanceRow(instance)
                        if index < app.instances.count - 1 {
                            Divider()
                                .padding(.leading, 34)
                                .padding(.trailing, 14)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("app-group-\(app.id)")
    }

    private func instanceRow(_ instance: WorkspacePresentationModel.TargetInstanceItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: instance.isConnected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(instance.isConnected ? Color.green : Color.secondary)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(instance.displayName)
                        .font(.callout.weight(.medium))

                    Text(instance.managementState.rawValue)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(stateColor(instance.managementState))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(stateColor(instance.managementState).opacity(0.1), in: Capsule())
                        .accessibilityIdentifier("target-instance-state-\(instance.id.rawValue)")

                    if let reason = instance.exclusionReason {
                        HStack(spacing: 3) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 9))
                            Text(reason.rawValue)
                                .font(.caption2)
                        }
                        .foregroundStyle(exclusionColor(reason))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(exclusionColor(reason).opacity(0.12), in: Capsule())
                        .accessibilityIdentifier("target-instance-exclusion-\(instance.id.rawValue)")
                    }
                }

                if let detail = instance.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let exclusionDetail = instance.exclusionDetail {
                    Text(exclusionDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let permissionDisclosure = instance.permissionDisclosure {
                    Label(permissionDisclosure, systemImage: "lock.open")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if instance.isConnected {
                Text("Connected")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            } else if instance.managementState == .unavailable {
                Text("Unavailable")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 4)
            } else {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { instance.isOptedIn },
                        set: { newValue in
                            model.perform {
                                try await model.setTargetOptIn(instance.id, isOptedIn: newValue)
                            }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.isBusy)
                .accessibilityIdentifier("target-instance-toggle-\(instance.id.rawValue)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityIdentifier("target-instance-row-\(instance.id.rawValue)")
    }

    private func stateColor(_ state: TargetManagementState) -> Color {
        switch state {
        case .connected: .green
        case .setupNeeded: .orange
        case .needsAttention: .red
        case .notSelected, .unavailable: .secondary
        }
    }

    private func exclusionColor(_ reason: RecommendationExclusionReason) -> Color {
        switch reason {
        case .unavailable: .secondary
        case .ambiguous, .conflicting: .orange
        case .experimental, .nonAllowlisted: .purple
        }
    }
}
