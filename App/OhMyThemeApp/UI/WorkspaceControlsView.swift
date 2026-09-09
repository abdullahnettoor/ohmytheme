import SwiftUI
import ThemeEngine
import ThemeModel

struct WorkspaceControlsView: View {
    private struct PendingRestoreAndDisconnectAction: Identifiable {
        let targetInstanceID: TargetInstanceID
        let targetName: String

        var id: TargetInstanceID { targetInstanceID }
        var title: String { "Restore and disconnect \(targetName)?" }
        var message: String {
            "Restore the captured Connection Baseline, remove managed setup that still matches, and stop managing this Target. External changes are never overwritten."
        }
    }

    @ObservedObject var model: WorkspacePresentationModel
    @State private var pendingConnectionAction: PendingRestoreAndDisconnectAction?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    workspaceStatusSection
                    targetSection
                    if !model.workspace.connectedTargetInstances.isEmpty {
                        connectionManagementSection
                    }
                    themeSection

                    if let progress = model.applyProgress, model.applyPlan == nil {
                        applyProgressBanner(progress: progress)
                    }
                    if let plan = model.applyPlan {
                        applyPlanSection(plan)
                    }
                    if let report = model.report {
                        reportSection(report)
                    }
                    if let persistenceError = model.persistenceError {
                        messageRow(
                            title: "Recovery storage unavailable",
                            detail: persistenceError,
                            systemImage: "externaldrive.badge.exclamationmark",
                            color: .red
                        )
                    }
                    if let operationError = model.operationError {
                        messageRow(
                            title: "Couldn't complete the operation",
                            detail: operationError,
                            systemImage: "exclamationmark.triangle.fill",
                            color: .red
                        )
                    }
                }
                .padding(18)
            }

            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            pendingConnectionAction?.title ?? "Manage Target",
            isPresented: Binding(
                get: { pendingConnectionAction != nil },
                set: { isPresented in
                    if !isPresented { pendingConnectionAction = nil }
                }
            ),
            titleVisibility: .visible,
            presenting: pendingConnectionAction
        ) { action in
            Button("Restore and Disconnect", role: .destructive) {
                perform(action)
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }

    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "paintpalette.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.workspaceName)
                    .font(.title3.weight(.semibold))
                Text("One theme for your connected workspace")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if model.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
        }
    }

    private var workspaceStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(
                "Workspace Status",
                detail: "Verified state across connected Targets compared with desired Theme Assignment."
            )

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verificationStatusTitle)
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("workspace-status-title")
                        if let timestamp = model.workspaceThemeStatus?.timestamp {
                            Text("Verified \(timestamp.formatted(date: .omitted, time: .standard))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("workspace-status-timestamp")
                        } else {
                            Text("Verification pending")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("workspace-status-timestamp")
                        }
                    }

                    Spacer()

                    statusBadge
                }

                HStack(spacing: 12) {
                    countChip(
                        count: model.appliedTargetsCount,
                        label: "Applied",
                        systemImage: "checkmark.circle.fill",
                        color: .green
                    )
                    countChip(
                        count: model.pendingTargetsCount,
                        label: "Pending",
                        systemImage: "clock.arrow.circlepath",
                        color: .orange
                    )
                    countChip(
                        count: model.needsAttentionTargetsCount,
                        label: "Needs Attention",
                        systemImage: "exclamationmark.triangle.fill",
                        color: .red
                    )
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("workspace-status-counts")

                if let activeOp = model.activeOperationSummary {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(activeOp)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("workspace-active-operation")
                }

                if let recovery = model.unresolvedRecovery {
                    messageRow(
                        title: "Recovery Requires Attention",
                        detail: recovery,
                        systemImage: "exclamationmark.shield.fill",
                        color: .orange
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    if let latestSetup = model.latestSetupReport {
                        HStack(spacing: 6) {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Latest Setup: \(latestSetup.outcomes.count) Target(s) configured")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("latest-setup-summary")
                    }

                    if let latestApply = model.latestApplyReport {
                        HStack(spacing: 6) {
                            Image(systemName: "paintbrush")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("Latest Apply: \(latestApply.outcomes.count) Target(s) processed")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("latest-apply-summary")
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(model.canUndoLastThemeChange ? "Undo available for last Theme change" : "Undo unavailable")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("undo-availability-summary")
                }
                .padding(.top, 2)
            }
            .padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("workspace-theme-status-section")
        }
    }

    private var verificationStatusTitle: String {
        guard let status = model.workspaceThemeStatus, !status.targetOutcomes.isEmpty else {
            return "No connected targets verified"
        }
        if status.needsAttentionCount > 0 {
            return "\(status.needsAttentionCount) Target\(status.needsAttentionCount == 1 ? "" : "s") need attention"
        }
        if status.isFullyApplied {
            return "Theme fully applied"
        }
        if status.appliedCount > 0 {
            return "Partially applied (\(status.appliedCount) of \(status.totalTargetCount))"
        }
        return "Theme pending apply"
    }

    private var statusBadge: some View {
        let text: String
        let color: Color
        if let status = model.workspaceThemeStatus, !status.targetOutcomes.isEmpty {
            if status.needsAttentionCount > 0 {
                text = "Needs Attention"
                color = .red
            } else if status.isFullyApplied {
                text = "Applied"
                color = .green
            } else if status.appliedCount > 0 {
                text = "Partially Applied"
                color = .orange
            } else {
                text = "Pending"
                color = .secondary
            }
        } else {
            text = "Unverified"
            color = .secondary
        }
        return Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
            .accessibilityIdentifier("workspace-status-badge")
    }

    private func countChip(count: Int, label: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(color)
            Text("\(count) \(label)")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Targets", detail: "Only connected Targets change when you apply.")

            if let emptyStateMessage = model.emptyStateMessage, model.applicationTargets.isEmpty {
                Text(emptyStateMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("workspace-empty-state")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.applicationTargets.enumerated()), id: \.element.id) { index, target in
                        targetRow(target)
                        if index < model.applicationTargets.count - 1 {
                            Divider().padding(.leading, 38)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var connectionManagementSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(
                "Connection recovery",
                detail: "Restore captured state and stop managing a connected Target."
            )

            VStack(spacing: 0) {
                ForEach(Array(model.workspace.connectedTargetInstances.enumerated()), id: \.element.id) {
                    index, instance in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(instance.displayName)
                                .font(.callout.weight(.medium))
                            Text("Connection Baseline available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Button("Disconnect…") {
                            pendingConnectionAction = PendingRestoreAndDisconnectAction(
                                targetInstanceID: instance.id,
                                targetName: instance.displayName
                            )
                        }
                        .fixedSize()
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("restore-and-disconnect-\(instance.id.rawValue)")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    if index < model.workspace.connectedTargetInstances.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func perform(_ action: PendingRestoreAndDisconnectAction) {
        pendingConnectionAction = nil
        model.perform {
            try await model.restoreAndDisconnect(action.targetInstanceID)
        }
    }

    private func targetRow(_ target: WorkspacePresentationModel.ApplicationTarget) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: target.systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(target.name)
                        .font(.callout.weight(.medium))
                    Text(target.state.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(targetColor(target.state))
                }
                Text(target.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if target.showsInstanceDetails {
                    ForEach(target.instanceDetails, id: \.self) { detail in
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                ForEach(target.connectionOptions) { option in
                    VStack(alignment: .leading, spacing: 4) {
                        if target.connectionOptions.count > 1 {
                            Text(option.name)
                                .font(.caption.weight(.medium))
                        }
                        if target.showsConnectionOptionDetails,
                            let detail = option.detail
                        {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let permissionDisclosure = option.permissionDisclosure {
                            Label(permissionDisclosure, systemImage: "lock.open")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if model.approvalRequiredFor == option.id,
                            let review = model.connectionReview
                        {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(review.expectedSideEffects, id: \.self) { effect in
                                    Label(effect, systemImage: "checkmark.circle")
                                }
                                ForEach(review.requiredPermissions, id: \.self) { permission in
                                    Label(permission, systemImage: "lock.open")
                                }
                                ForEach(review.userActions, id: \.title) { action in
                                    Label(
                                        "\(action.title): \(action.detail)",
                                        systemImage: "person.crop.circle.badge.exclamationmark")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Button(model.approvalRequiredFor == option.id ? "Approve and connect" : "Review connection") {
                            model.perform {
                                if model.approvalRequiredFor == option.id {
                                    try await model.connect(option.id)
                                } else {
                                    try await model.reviewConnection(option.id)
                                }
                            }
                        }
                        .controlSize(.small)
                        .disabled(model.isBusy || !model.isReady || model.persistenceError != nil)
                    }
                    .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("target-\(target.id)")
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(
                "Theme",
                detail: "The desired Theme Variant is saved separately from Target outcomes shown below."
            )

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.desiredThemeTitle)
                            .font(.headline)
                            .accessibilityIdentifier("desired-theme-title")

                        Text(model.desiredThemeExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(model.desiredThemeStatus)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("desired-theme-status")
                }

                if let selected = model.bundledThemeVariants.first(where: {
                    $0.variantID == model.selectedThemeVariantID
                }) {
                    HStack(spacing: 10) {
                        ThemeSwatchStrip(preview: selected.preview)

                        Text(
                            "\(selected.source.type.rawValue.capitalized) source · "
                                + selected.appearance.rawValue.capitalized
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected.source.attribution)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text("Revision: \(selected.source.revision)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Picker(
                    "Theme Variant",
                    selection: Binding(
                        get: { model.selectedThemeVariantID },
                        set: { model.selectThemeVariant($0) }
                    )
                ) {
                    Text("Choose a Theme Variant").tag(nil as String?)
                    ForEach(model.bundledThemeVariants, id: \.variantID) { variant in
                        Text(variant.name).tag(variant.variantID as String?)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Theme Variant")
                .accessibilityIdentifier("theme-variant-picker")
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("overview-desired-theme-section")

            Button {
                Task {
                    _ = try? await model.applyDesiredTheme()
                }
            } label: {
                Label(model.isApplyingTheme ? "Applying Theme..." : "Apply Theme", systemImage: "paintbrush.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canApplyThemes || model.selectedThemeVariantID == nil || model.isBusy)
            .accessibilityIdentifier("apply-theme-button")
        }
    }

    private func applyPlanSection(_ plan: ApplyPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(
                "Apply Plan", detail: "Prepared for \(plan.targetInstanceIDs.count) Target Instances.")

            if let explanation = plan.preflightExplanation(acknowledgedUnavailableTargets: model.acknowledgedUnavailableTargetInstanceIDs) {
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("preflight-review-explanation")
            }

            let reasons = plan.preflightReviewReasons(acknowledgedUnavailableTargets: model.acknowledgedUnavailableTargetInstanceIDs)
            if !reasons.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(reasons) { reason in
                        let targetName: String? = reason.targetInstanceID.flatMap { targetID in
                            model.workspace.connectedTargetInstances.first(where: { $0.id == targetID })?.displayName
                                ?? model.applicationTargets.flatMap(\.instances).first(where: { $0.id == targetID })?.displayName
                        }
                        let reasonTitle = targetName.map { "\($0): \(reason.title)" } ?? reason.title
                        messageRow(
                            title: reasonTitle,
                            detail: reason.detail,
                            systemImage: reasonIcon(category: reason.category),
                            color: reasonColor(category: reason.category)
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                planFact("Source", value: plan.sourceType.rawValue.capitalized)
                planFact("Expected reach", value: reachLabel(plan.activationReach))
                planFact("Revision", value: plan.sourceRevision)

                ForEach(plan.targetPlans, id: \.targetInstanceID) { targetPlan in
                    ForEach(targetPlan.expectedSideEffects, id: \.self) { sideEffect in
                        messageRow(
                            title: "Expected change",
                            detail: sideEffect,
                            systemImage: "doc.text.magnifyingglass",
                            color: .secondary
                        )
                    }
                }
            }

            if let progress = model.applyProgress {
                applyProgressBanner(progress: progress)
            }

            if !model.isApplyingTheme {
                let hasReview = plan.hasReviewConditions(acknowledgedUnavailableTargets: model.acknowledgedUnavailableTargetInstanceIDs)
                Button {
                    Task {
                        _ = try? await model.applyPreparedPlan()
                    }
                } label: {
                    Label(hasReview ? "Apply to ready Targets" : "Apply Theme", systemImage: "paintbrush.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.isBusy
                        || plan.readyTargetPlans.isEmpty
                )
                .accessibilityIdentifier("apply-plan")
            }
        }
        .padding(14)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func reasonIcon(category: PreflightReviewReason.Category) -> String {
        switch category {
        case .conflict: "exclamationmark.triangle.fill"
        case .ownership: "exclamationmark.circle"
        case .permission: "lock.open"
        case .ambiguousTarget: "questionmark.circle"
        case .setupNeeded: "wrench.and.screwdriver"
        case .unavailable: "minus.circle"
        }
    }

    private func reasonColor(category: PreflightReviewReason.Category) -> Color {
        switch category {
        case .conflict, .ambiguousTarget: .red
        case .ownership, .permission, .setupNeeded: .orange
        case .unavailable: .secondary
        }
    }

    private func reportSection(_ report: WorkspacePresentationModel.PresentedReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.sectionTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack {
                Text(report.title)
                    .font(.headline)
                Spacer()
                Image(
                    systemName: report.groups.contains(where: { group in
                        group.outcomes.contains(where: \.isProblem)
                    }) ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
                )
                .foregroundStyle(
                    report.groups.contains(where: { group in
                        group.outcomes.contains(where: \.isProblem)
                    }) ? .orange : .green)
            }

            ForEach(report.groups) { group in
                VStack(alignment: .leading, spacing: 7) {
                    Text(group.targetName)
                        .font(.callout.weight(.semibold))
                    ForEach(Array(group.outcomes.enumerated()), id: \.offset) { _, outcome in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(outcome.capability)
                                Spacer()
                                Text(outcome.configuration)
                                    .foregroundStyle(outcome.isProblem ? .orange : .secondary)
                            }
                            .font(.caption.weight(.medium))

                            if let reach = outcome.reach {
                                Text(reach)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let detail = outcome.detail {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(outcome.userActions, id: \.self) { userAction in
                                Label(userAction, systemImage: "arrow.right.circle")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            Text(outcome.rollback)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            if report.kind == .setup, model.canRetryRemainingSetup {
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
        .accessibilityIdentifier("theme-apply-report")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                model.perform {
                    _ = try await model.undoLastThemeChange()
                }
            } label: {
                Label("Undo Last Theme Change", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.canUndoLastThemeChange || model.isBusy)
            .accessibilityIdentifier("undo-last-theme-change")

        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func planFact(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func messageRow(
        title: String,
        detail: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func targetColor(_ state: WorkspacePresentationModel.ApplicationTarget.State) -> Color {
        switch state {
        case .connected: .green
        case .setupNeeded: .orange
        case .needsAttention: .red
        case .notSelected, .unavailable: .secondary
        }
    }

    private func reachLabel(_ reach: ActivationReach) -> String {
        switch reach {
        case .currentInstances: "Current windows"
        case .nextPrompt: "Next prompt"
        case .newProcessesOnly: "Next launch"
        case .reloadRequired: "Reload required"
        case .unavailable: "Unavailable"
        }
    }
    private func applyProgressBanner(progress: ApplyProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(progress.isComplete ? "Apply Complete" : (progress.activeStepName.map { "Applying to \($0)..." } ?? "Applying Theme..."))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("apply-progress-title")
                Spacer()
                Text("\(progress.completedCount) of \(progress.totalCount)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("apply-progress-count")
            }

            ProgressView(value: progress.fractionCompleted)
                .accessibilityIdentifier("apply-progress-bar")

            VStack(spacing: 6) {
                ForEach(progress.steps) { step in
                    HStack(spacing: 8) {
                        Text(step.displayName)
                            .font(.caption.weight(.medium))
                        Spacer()
                        applyStepBadge(status: step.status)
                    }
                    .accessibilityIdentifier("apply-step-\(step.targetInstanceID.rawValue)")
                }
            }
            .padding(.top, 4)

            if model.isApplyingTheme {
                Button(role: .cancel) {
                    Task {
                        await model.cancelRemainingApply()
                    }
                } label: {
                    HStack {
                        if model.isCancellingRemainingApply {
                            ProgressView()
                                .controlSize(.small)
                            Text("Cancelling Remaining...")
                        } else {
                            Label("Cancel Remaining", systemImage: "xmark.circle")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(model.isCancellingRemainingApply)
                .accessibilityIdentifier("cancel-remaining-apply-button")
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("apply-progress-banner")
    }

    @ViewBuilder
    private func applyStepBadge(status: ApplyProgress.StepStatus) -> some View {
        switch status {
        case .waiting:
            Label("Waiting", systemImage: "clock")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1), in: Capsule())
                .accessibilityIdentifier("apply-status-waiting")
        case .applying:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Applying")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .accessibilityIdentifier("apply-status-applying")
        case .completed:
            Label("Completed", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.1), in: Capsule())
                .accessibilityIdentifier("apply-status-completed")
        case .skipped:
            Label("Skipped", systemImage: "forward.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .accessibilityIdentifier("apply-status-skipped")
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.1), in: Capsule())
                .accessibilityIdentifier("apply-status-failed")
        case .conflict:
            Label("Conflict", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12), in: Capsule())
                .accessibilityIdentifier("apply-status-conflict")
        case .permissionRequired:
            Label("Permission Required", systemImage: "lock.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12), in: Capsule())
                .accessibilityIdentifier("apply-status-permission")
        }
    }

}

#Preview {
    WorkspaceControlsView(
        model: WorkspacePresentationModel(
            runtime: FakeWorkspaceRuntime(
                workspace: WorkspaceStore().workspace,
                themePacks: (try? BundledThemeCatalog().load()) ?? []
            )
        )
    )

}
