import SwiftUI
import ThemeEngine

struct WorkspaceMenuView: View {
    @ObservedObject var model: WorkspaceMenuModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    targetSection
                    themeSection

                    if let preview = model.preview {
                        previewSection(preview)
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
        .frame(width: 380, height: 640)

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

    private func targetRow(_ target: WorkspaceMenuModel.ApplicationTarget) -> some View {
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
            sectionHeading("Theme Variant", detail: "Preview every connected Target before anything changes.")

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

            if let selected = model.bundledThemeVariants.first(where: {
                $0.variantID == model.selectedThemeVariantID
            }) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(selected.sourceType.capitalized) source · \(selected.appearance.capitalized)")
                        .font(.caption.weight(.medium))
                    Text(selected.attribution)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(selected.sourceRevision)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Button {
                model.perform {
                    _ = try await model.prepareSelectedTheme()
                }
            } label: {
                Label("Preview workspace change", systemImage: "eye")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canApplyThemes || model.selectedThemeVariantID == nil || model.isBusy)
        }
    }

    private func previewSection(_ preview: ThemePreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading(
                "Workspace preview", detail: "Prepared for \(preview.targetInstanceIDs.count) Target Instances.")

            VStack(alignment: .leading, spacing: 7) {
                previewFact("Source", value: preview.sourceType.rawValue.capitalized)
                previewFact("Expected reach", value: reachLabel(preview.activationReach))
                previewFact("Revision", value: preview.sourceRevision)

                ForEach(preview.targetPlans, id: \.targetInstanceID) { plan in
                    ForEach(plan.expectedSideEffects, id: \.self) { sideEffect in
                        messageRow(
                            title: "Expected change",
                            detail: sideEffect,
                            systemImage: "doc.text.magnifyingglass",
                            color: .secondary
                        )
                    }
                    ForEach(plan.requiredPermissions, id: \.self) { permission in
                        messageRow(
                            title: "Permission needed",
                            detail: permission,
                            systemImage: "lock.open",
                            color: .orange
                        )
                    }
                }
                ForEach(preview.setupNeeds, id: \.title) { action in
                    messageRow(
                        title: action.title,
                        detail: action.detail,
                        systemImage: "wrench.and.screwdriver",
                        color: .orange
                    )
                }
                ForEach(preview.preparationFailures, id: \.targetInstanceID) { failure in
                    messageRow(
                        title: "Could not prepare a Target",
                        detail: failure.detail,
                        systemImage: "xmark.circle.fill",
                        color: .red
                    )
                }
                ForEach(preview.unavailableTargetInstanceIDs, id: \.self) { _ in
                    messageRow(
                        title: "Target unavailable",
                        detail: "No compatible adapter prepared this Target Instance.",
                        systemImage: "minus.circle",
                        color: .secondary
                    )
                }
                ForEach(preview.conflicts, id: \.self) { conflict in
                    messageRow(
                        title: "Conflict",
                        detail: conflict,
                        systemImage: "exclamationmark.triangle.fill",
                        color: .orange
                    )
                }
            }

            Button {
                model.perform {
                    _ = try await model.applyPreparedPreview()
                }
            } label: {
                Label("Apply to ready Targets", systemImage: "paintbrush.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.isBusy
                    || preview.targetPlans.isEmpty
            )
            .accessibilityIdentifier("apply-theme-preview")
        }
        .padding(14)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func reportSection(_ report: WorkspaceMenuModel.PresentedReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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

            Spacer()

            Button("Quit") {
                model.quit()
            }
            .keyboardShortcut("q")
            .accessibilityIdentifier("quit-oh-my-theme")
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

    private func previewFact(_ label: String, value: String) -> some View {
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

    private func targetColor(_ state: WorkspaceMenuModel.ApplicationTarget.State) -> Color {
        switch state {
        case .ready: .green
        case .setupNeeded: .orange
        case .unavailable: .secondary
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
}

#Preview {
    WorkspaceMenuView(
        model: WorkspaceMenuModel(
            workspace: WorkspaceStore().workspace,
            themePacks: (try? BundledThemeCatalog().load()) ?? [],
            quitAction: {}
        )
    )
}
