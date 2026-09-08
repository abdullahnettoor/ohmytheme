import SwiftUI
import ThemeEngine
import ThemeModel

struct SetupPlanReviewView: View {
    @ObservedObject var model: WorkspacePresentationModel
    let plan: SetupPlan
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let invalidationReason = model.setupPlanInvalidationReason {
                        invalidationBanner(reason: invalidationReason)
                    }

                    if let progress = model.setupProgress {
                        progressBanner(progress: progress)
                    }

                    executionOrderSection

                    if !plan.sharedEffects.isEmpty {
                        sharedEffectsSection
                    }

                    aggregateDetailsSection

                    recoverySection
                }
                .padding(24)
            }

            Divider()
            footer
        }
        .frame(minWidth: 540, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await model.revalidateSetupPlan()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !model.isExecutingSetup {
                    await model.revalidateSetupPlan()
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Review Setup Plan")
                        .font(.title3.weight(.bold))
                    Text("\(plan.targetInstanceIDs.count) selected")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Text("Verify aggregate configuration, permissions, and execution order before connecting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.dismissSetupPlan()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dismiss-setup-plan-button")
        }
        .padding(18)
    }

    private func invalidationBanner(reason: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 4) {
                Text("Preconditions Changed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A new aggregate confirmation is required before proceeding.")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)

                Button("Review Updated Plan") {
                    Task {
                        await model.prepareSetupPlan()
                    }
                }
                .controlSize(.small)
                .padding(.top, 4)
                .accessibilityIdentifier("review-updated-plan-button")
            }

            Spacer()
        }
        .padding(12)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
        )
        .accessibilityIdentifier("setup-plan-invalidated-banner")
    }

    private var executionOrderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Execution Order")
                    .font(.headline)
                Spacer()
                Text("Engine-owned stable sequence")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(Array(plan.targetInstanceIDs.enumerated()), id: \.element) { index, targetID in
                    let failure = plan.preparationFailures.first { $0.targetInstanceID == targetID }
                    let ownership = plan.ownershipDetails.first { $0.targetInstanceID == targetID }
                    let targetPlan = plan.targetPlans.first { $0.targetInstanceID == targetID }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .frame(width: 20, height: 20)
                                .background(Color.accentColor.opacity(0.15), in: Circle())
                                .foregroundStyle(Color.accentColor)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(targetDisplayName(for: targetID))
                                    .font(.subheadline.weight(.medium))
                                if let adapterID = ownership?.adapterID {
                                    Text(adapterID)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if let step = model.setupProgress?.steps.first(where: { $0.targetInstanceID == targetID }) {
                                stepBadge(status: step.status)
                            } else if failure != nil {
                                Label("Preparation Failed", systemImage: "xmark.circle.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red.opacity(0.1), in: Capsule())
                            } else {
                                Label("Ready", systemImage: "checkmark.circle.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.1), in: Capsule())
                            }
                        }

                        if let failure {
                            Text(failure.detail)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .padding(.leading, 30)
                        }

                        if let ownership {
                            if ownership.isConsequential, let detail = ownership.consequentialDetail {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.shield.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                    Text(detail)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.orange)
                                }
                                .padding(.leading, 30)
                            }

                            if let targetPlan, !targetPlan.userActions.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(targetPlan.userActions.enumerated()), id: \.offset) { _, action in
                                        userActionRow(action)
                                    }
                                }
                                .padding(.leading, 30)
                            }

                            if !ownership.routineDetails.isEmpty {
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(ownership.summary)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        ForEach(ownership.routineDetails, id: \.self) { detail in
                                            Text("• \(detail)")
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                } label: {
                                    Text("Routine managed details")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.leading, 30)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("setup-plan-step-\(targetID.rawValue)")
                }
            }
        }
    }

    private var sharedEffectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shared Artifacts & Setup Effects")
                .font(.headline)
            Text("Shared setup details are grouped once for every affected target.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(plan.sharedEffects) { effect in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(effect.name)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if effect.isConsequential {
                                Text("Permission / Consequential")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.12), in: Capsule())
                            }
                        }

                        if let detail = effect.detail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 6) {
                            Text("Applies to:")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ForEach(effect.affectedTargetNames, id: \.self) { name in
                                Text(name)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("shared-effect-\(effect.name)")
                }
            }
        }
    }

    private var aggregateDetailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aggregate Details")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Activation Reach")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text(reachDescription(plan.activationReach))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !plan.userActions.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Required User Actions & Approvals")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                        ForEach(Array(plan.userActions.enumerated()), id: \.offset) { _, action in
                            userActionRow(action)
                        }
                    }
                }

                if !plan.requiredPermissions.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Required Permissions")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                        ForEach(plan.requiredPermissions, id: \.self) { perm in
                            Label(perm, systemImage: "lock.open.trianglebadge.exclamationmark")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !plan.expectedSideEffects.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Expected Side Effects")
                            .font(.caption.weight(.medium))
                        ForEach(plan.expectedSideEffects, id: \.self) { effect in
                            Text("• \(effect)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()
                HStack {
                    Text("Precondition Digest")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Text(plan.discoveryAndSelectionDigest.prefix(12) + "...")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise.circle")
                    .foregroundStyle(.tint)
                Text("Zero External Writes Guarantee")
                    .font(.subheadline.weight(.semibold))
            }
            Text(
                "Reviewing this plan performed zero writes to your system and created no connection baseline. "
                    + plan.recoveryBehavior
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Button("Dismiss") {
                model.dismissSetupPlan()
                dismiss()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dismiss-setup-plan-footer-button")

            Spacer()

            if model.isExecutingSetup {
                Button(model.isCancellingRemainingSetup ? "Cancelling Remaining..." : "Cancel Remaining") {
                    Task {
                        await model.cancelRemainingSetup()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.isCancellingRemainingSetup)
                .accessibilityIdentifier("cancel-remaining-setup-button")
            } else if model.isSetupPlanInvalidated {
                Button("Update Plan") {
                    Task {
                        await model.prepareSetupPlan()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isExecutingSetup || model.isBusy)
                .accessibilityIdentifier("revalidate-setup-plan-button")
            } else {
                Button(model.isExecutingSetup ? "Configuring Apps..." : "Configure Selected Apps") {
                    Task {
                        let isValid = await model.confirmSetupPlan()
                        guard isValid else { return }
                        do {
                            _ = try await model.executeSetupPlan()
                        } catch {
                            // Captured on model.operationError
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !plan.hasReadyTargets || model.isSetupPlanInvalidated || model.isExecutingSetup || model.isBusy
                )
                .accessibilityIdentifier("confirm-setup-plan-button")
            }
        }
        .padding(18)
    }

    private func progressBanner(progress: SetupProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(progress.isComplete ? "Setup Complete" : "Configuring Apps...")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(progress.completedCount) of \(progress.totalCount)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress.fractionCompleted)
            if !progress.isComplete {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        progress.currentAction ?? progress.activeStepName.map { "Configuring \($0)..." }
                            ?? "Preparing..."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("setup-progress-banner")
    }

    @ViewBuilder
    private func stepBadge(status: SetupProgress.StepStatus) -> some View {
        switch status {
        case .waiting:
            Label("Waiting", systemImage: "clock")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1), in: Capsule())
        case .configuring:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Configuring")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.1), in: Capsule())
        case .unchanged:
            Label("Unchanged", systemImage: "checkmark.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.1), in: Capsule())
        case .needsPermission:
            Label("Permission Needed", systemImage: "lock.shield.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12), in: Capsule())
        case .needsAction:
            Label("Action Required", systemImage: "hand.tap.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12), in: Capsule())
        case .conflict:
            Label("Conflict", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.yellow)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.yellow.opacity(0.15), in: Capsule())
        case .failed:
            Label("Failed", systemImage: "xmark.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.1), in: Capsule())
        case .unavailable:
            Label("Unavailable", systemImage: "slash.circle")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        case .recoveryRequired:
            Label("Recovery Required", systemImage: "shield.slash.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.12), in: Capsule())
        }
    }

    private func userActionRow(_ action: UserAction) -> some View {
        let isConsequential = action.kind == .approval || action.kind == .permission
        let systemImage: String =
            switch action.kind {
            case .approval, .permission: "exclamationmark.shield.fill"
            case .reload: "arrow.triangle.2.circlepath"
            case .instruction: "hand.tap.fill"
            }

        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(isConsequential ? Color.orange : Color.secondary)
                .font(.caption2)
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isConsequential ? Color.orange : Color.primary)
                Text(action.detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func targetDisplayName(for id: TargetInstanceID) -> String {
        for app in model.applicationTargets {
            if let instance = app.instances.first(where: { $0.id == id }) {
                return instance.displayName
            }
        }
        return id.rawValue
    }

    private func reachDescription(_ reach: ActivationReach) -> String {
        switch reach {
        case .currentInstances: "Applies immediately to current instances"
        case .nextPrompt: "Applies at next shell prompt"
        case .newProcessesOnly: "Applies to newly launched processes"
        case .reloadRequired: "Reload required"
        case .unavailable: "Unavailable or blocked"
        }
    }
}
