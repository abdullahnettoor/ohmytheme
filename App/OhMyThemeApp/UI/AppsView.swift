import SwiftUI
import ThemeEngine
import ThemeModel

struct AppsView: View {
    @ObservedObject var model: WorkspacePresentationModel
    @State private var expandedApps: Set<String> = []
    @State private var confirmsRelinquishment = false

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

                if !model.replacementSuggestions.isEmpty {
                    replacementSection(model.replacementSuggestions)
                }

                if let report = model.report, report.kind == .setup {
                    setupReportSection(report)
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
            isPresented: Binding(
                get: { model.disconnectReview != nil },
                set: { isPresented in
                    if !isPresented {
                        model.dismissDisconnectReview()
                        confirmsRelinquishment = false
                    }
                }
            )
        ) {
            if let review = model.disconnectReview {
                disconnectReviewSheet(review)
            }
        }
    }

    private func disconnectReviewSheet(_ review: DisconnectReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(review.isSafeToRestore ? "Restore and disconnect?" : "Restoration blocked")
                .font(.headline)
                .accessibilityIdentifier("disconnect-review-title")
            Text(review.restorationSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("disconnect-review-summary")
            if !review.expectedEffects.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Expected changes")
                        .font(.caption.weight(.semibold))
                    ForEach(review.expectedEffects, id: \.self) { effect in
                        Label(effect, systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let conflict = review.conflictDetail {
                Label("External change detected: \(conflict)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("disconnect-review-conflict")
                Text(
                    "The target stays connected until you choose a safe resolution. "
                        + "Relinquishing leaves current configuration untouched."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !review.residualPathsIfRelinquished.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("If you relinquish management, these remain in place:")
                        .font(.caption.weight(.semibold))
                    ForEach(review.residualPathsIfRelinquished, id: \.self) { path in
                        Text(path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("disconnect-review-residuals")
            }
            if let relinquished = model.relinquishReport,
                relinquished.targetInstanceID == review.targetInstanceID
            {
                Label(relinquished.detail, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("relinquish-report-detail")
            }
            HStack(spacing: 10) {
                Button("Cancel", role: .cancel) {
                    model.dismissDisconnectReview()
                    confirmsRelinquishment = false
                }
                Spacer()
                if review.isSafeToRestore {
                    Button("Restore and Disconnect", role: .destructive) {
                        model.perform {
                            try await model.restoreAndDisconnect(review.targetInstanceID)
                        }
                        confirmsRelinquishment = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("confirm-restore-and-disconnect")
                } else {
                    if confirmsRelinquishment {
                        Button("Relinquish and Keep Files", role: .destructive) {
                            model.perform {
                                try await model.relinquishManagement(review.targetInstanceID)
                            }
                            confirmsRelinquishment = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("confirm-relinquish-management")
                    } else {
                        Button("Review Relinquishment…", role: .destructive) {
                            confirmsRelinquishment = true
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("review-relinquishment-button")
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(minWidth: 380)
    }

    private func setupReportSection(_ report: WorkspacePresentationModel.PresentedReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(report.sectionTitle)
                .font(.headline)
            Text(report.title)
                .font(.subheadline.weight(.semibold))
            ForEach(report.groups) { group in
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.targetName)
                        .font(.caption.weight(.semibold))
                    ForEach(Array(group.outcomes.enumerated()), id: \.offset) { _, outcome in
                        Text("\(outcome.capability): \(outcome.configuration)")
                            .font(.caption)
                            .foregroundStyle(outcome.isProblem ? .orange : .secondary)
                        if let detail = outcome.detail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if model.canRetryRemainingSetup {
                Button("Retry Remaining") {
                    Task {
                        await model.retryRemainingSetup()
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("retry-remaining-setup-button")
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("setup-report")
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
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Connected")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Button("Disconnect…") {
                        model.perform {
                            try await model.reviewDisconnect(instance.id)
                        }
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("disconnect-review-\(instance.id.rawValue)")
                }
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

    private func replacementSection(_ suggestions: [ConnectionReplacementSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection Replacement")
                .font(.headline)
            Text(
                "A connected Target disappeared. Review the old and new identities below. "
                    + "Nothing transfers automatically."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            ForEach(suggestions, id: \.oldInstance.id) { suggestion in
                replacementCard(suggestion)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("connection-replacement-section")
    }

    private func replacementCard(_ suggestion: ConnectionReplacementSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Previous Target (still connected)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(suggestion.oldInstance.displayName)
                    .font(.callout.weight(.medium))
                Text(suggestion.oldInstance.id.rawValue)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let capturedAt = suggestion.oldBaselineCapturedAt {
                    Text(
                        "Unavailable. Connection Baseline retained from \(capturedAt.formatted(date: .abbreviated, time: .shortened))."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Unavailable. No Connection Baseline recorded.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("replacement-old-\(suggestion.oldInstance.id.rawValue)")

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Suggested replacement (not selected)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(suggestion.newCandidates, id: \.id) { candidate in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.displayName)
                                .font(.callout.weight(.medium))
                            Text(candidate.id.rawValue)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Button("Opt In") {
                            model.perform {
                                try await model.setTargetOptIn(candidate.id, isOptedIn: true)
                            }
                        }
                        .controlSize(.small)
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("replacement-opt-in-\(candidate.id.rawValue)")
                    }
                }
                Text(
                    "Opting in only selects the new instance. Connecting it follows the normal Setup Plan review, "
                        + "and the previous Target keeps its own opt-in, baseline, and recovery state."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("connection-replacement-\(suggestion.oldInstance.id.rawValue)")
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
