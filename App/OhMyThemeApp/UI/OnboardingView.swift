import SwiftUI
import ThemeEngine
import ThemeModel

struct OnboardingView: View {
    @ObservedObject var model: WorkspacePresentationModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            Group {
                switch model.currentOnboardingStep {
                case .contract:
                    OnboardingContractStepView(model: model)
                case .desiredTheme:
                    OnboardingThemeStepView(model: model)
                case .targetOptIns:
                    OnboardingTargetOptInsStepView(model: model)
                case .setupPlanReview:
                    OnboardingSetupPlanStepView(model: model)
                case .setupTransaction:
                    OnboardingSetupTransactionStepView(model: model)
                case .setupResults:
                    OnboardingSetupResultsStepView(model: model)
                case .initialApply:
                    OnboardingInitialApplyStepView(model: model)
                case .overview:
                    Color.clear.onAppear {
                        model.completeOnboarding()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("onboarding-view")
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "paintpalette.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Oh My Theme")
                    .font(.headline.weight(.semibold))
                Text(stepBreadcrumb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !model.isExecutingSetup && !model.isApplyingTheme {
                Button("Set Up Later") {
                    model.deferOnboarding()
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("onboarding-top-set-up-later-button")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var stepBreadcrumb: String {
        switch model.currentOnboardingStep {
        case .contract:
            return "Step 1 of 6: Safety Contract"
        case .desiredTheme:
            return "Step 2 of 6: Desired Theme"
        case .targetOptIns:
            return "Step 3 of 6: Connect Apps"
        case .setupPlanReview, .setupTransaction:
            return "Step 4 of 6: Setup"
        case .setupResults:
            return "Step 5 of 6: Setup Results"
        case .initialApply:
            return "Step 6 of 6: Initial Apply"
        case .overview:
            return "Setup Complete"
        }
    }
}

// MARK: - Step 1: Contract

struct OnboardingContractStepView: View {
    @ObservedObject var model: WorkspacePresentationModel

    var body: some View {
        VStack(spacing: 24) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Deterministic, Reversible Theme Coordination")
                            .font(.title2.weight(.bold))
                        Text("Oh My Theme coordinates system and application appearance with absolute safety guarantees.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    contractCard(
                        icon: "arrow.uturn.backward.circle.fill",
                        title: "Reversible by Design",
                        description: "Every file modification is preceded by a durable Connection Baseline. You can undo or disconnect at any time to restore your exact prior bytes."
                    )

                    contractCard(
                        icon: "shield.lefthalf.filled",
                        title: "No Shell Scripts or GUI Automation",
                        description: "Oh My Theme operates exclusively through narrow TOML transforms, official companion protocols, and platform APIs. It never runs arbitrary shell scripts or private preference commands."
                    )

                    contractCard(
                        icon: "doc.text.magnifyingglass",
                        title: "Narrow Ownership",
                        description: "We edit only specifically designated include blocks and managed configuration sections. Existing custom comments and unrelated settings remain untouched."
                    )

                    contractCard(
                        icon: "hand.raised.circle.fill",
                        title: "Explicit Approvals",
                        description: "Symbolic links, unusual configurations, and external changes are never silently overwritten. Any deviation halts and requests your explicit confirmation."
                    )
                }
                .padding(28)
            }

            Divider()

            HStack {
                Button("Set Up Later") {
                    model.deferOnboarding()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("onboarding-contract-defer-button")

                Spacer()

                Button("Agree & Continue") {
                    model.acknowledgeContract()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("onboarding-agree-button")
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
    }

    private func contractCard(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Step 2: Desired Theme

struct OnboardingThemeStepView: View {
    @ObservedObject var model: WorkspacePresentationModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Choose Your Desired Theme")
                            .font(.title2.weight(.bold))
                        Text("Select a theme to coordinate across your apps. You can change this at any time.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if model.bundledThemeVariants.isEmpty {
                        Text("Loading theme packs…")
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                            ForEach(model.bundledThemeVariants) { variant in
                                Button {
                                    model.selectThemeVariant(variant.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text(variant.preview.displayName)
                                                .font(.headline)
                                                .lineLimit(1)
                                            Spacer()
                                            if model.selectedThemeVariantID == variant.id {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(.tint)
                                            }
                                        }
                                        ThemeSwatchStrip(preview: variant.preview)
                                            .frame(height: 18)
                                    }
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        model.selectedThemeVariantID == variant.id
                                            ? Color.accentColor.opacity(0.12)
                                            : Color(nsColor: .controlBackgroundColor)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(
                                                model.selectedThemeVariantID == variant.id
                                                    ? Color.accentColor
                                                    : Color.secondary.opacity(0.2),
                                                lineWidth: model.selectedThemeVariantID == variant.id ? 2 : 1
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("onboarding-theme-\(variant.id)")
                            }
                        }
                    }
                }
                .padding(28)
            }

            Divider()

            HStack {
                Button("Back") {
                    model.goToOnboardingStep(.contract)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboarding-theme-back-button")

                Spacer()

                Button("Set Up Later") {
                    model.deferOnboarding()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button("Continue") {
                    model.acknowledgeContract()
                    model.goToOnboardingStep(.targetOptIns)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.selectedThemeVariantID == nil)
                .accessibilityIdentifier("onboarding-theme-continue-button")
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }
}

// MARK: - Step 3: Target Opt-ins

struct OnboardingTargetOptInsStepView: View {
    @ObservedObject var model: WorkspacePresentationModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connect Your Apps")
                            .font(.title2.weight(.bold))
                        Text("Select which applications and surfaces Oh My Theme should configure.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if !model.hasRecommendedTargets {
                        noTargetsCard
                    } else {
                        HStack {
                            Text("Supported Applications")
                                .font(.headline)
                            Spacer()
                            if model.canSelectAllRecommended {
                                Button("Select All Recommended") {
                                    Task { try? await model.selectAllRecommended() }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("select-all-recommended-button")
                            }
                        }

                        VStack(spacing: 12) {
                            ForEach(model.applicationTargets) { appTarget in
                                appTargetCard(appTarget)
                            }
                        }
                    }
                }
                .padding(28)
            }

            Divider()

            HStack {
                Button("Back") {
                    model.goToOnboardingStep(.desiredTheme)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboarding-targets-back-button")

                Spacer()

                Button("Set Up Later") {
                    model.deferOnboarding()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if model.hasRecommendedTargets || !model.applicationTargets.isEmpty {
                    Button("Review Setup Plan") {
                        Task {
                            await model.prepareSetupPlan()
                            model.goToOnboardingStep(.setupPlanReview)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canReviewSetupPlan)
                    .accessibilityIdentifier("onboarding-review-setup-plan-button")
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }

    private var noTargetsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No Recommended Targets Found")
                        .font(.headline)
                    Text(model.checkedApplicationsSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button("Rescan") {
                    Task { try? await model.refreshTargets() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("onboarding-rescan-button")

                Button("Set Up Later") {
                    model.deferOnboarding()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("onboarding-no-targets-defer-button")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("onboarding-no-targets-card")
    }

    private func appTargetCard(_ appTarget: WorkspacePresentationModel.ApplicationTarget) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: appTarget.systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                Text(appTarget.name)
                    .font(.headline)
                Spacer()
                Text(appTarget.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(appTarget.instances) { instance in
                HStack(spacing: 10) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { instance.isOptedIn },
                            set: { isOptedIn in
                                Task {
                                    try? await model.setTargetOptIn(instance.id, isOptedIn: isOptedIn)
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .disabled(instance.isConnected)
                    .accessibilityIdentifier("toggle-\(instance.id.rawValue)")

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(instance.displayName)
                                .font(.body)
                            if instance.isRecommended {
                                Text("Recommended")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                            }
                            if instance.isConnected {
                                Text("Connected")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.green)
                            }
                        }
                        if let detail = instance.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Step 4: Setup Plan Review

struct OnboardingSetupPlanStepView: View {
    @ObservedObject var model: WorkspacePresentationModel

    private func sharedEffectText(_ effect: SetupSharedEffect) -> String {
        if let detail = effect.detail, !detail.isEmpty {
            return "• " + effect.name + ": " + detail
        }
        return "• " + effect.name
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Review Setup Plan")
                            .font(.title2.weight(.bold))
                        Text("Review the aggregate configuration plan before applying changes to your system.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let plan = model.setupPlan {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Target Execution Order (\(plan.targetInstanceIDs.count) selected)")
                                .font(.headline)

                            ForEach(plan.targetInstanceIDs, id: \.rawValue) { targetID in
                                HStack(spacing: 8) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 6))
                                        .foregroundStyle(.tint)
                                    Text(targetID.rawValue)
                                        .font(.system(.body, design: .monospaced))
                                }
                                .padding(.leading, 8)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        if !plan.sharedEffects.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Shared System Effects")
                                    .font(.headline)
                                ForEach(plan.sharedEffects) { effect in
                                    Text(sharedEffectText(effect))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    } else {
                        ProgressView("Preparing setup plan…")
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }
                }
                .padding(28)
            }

            Divider()

            HStack {
                Button("Back") {
                    model.dismissSetupPlan()
                    model.goToOnboardingStep(.targetOptIns)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("onboarding-plan-back-button")

                Spacer()

                Button("Set Up Later") {
                    model.deferOnboarding()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button("Configure Selected Apps") {
                    Task {
                        try? await model.executeSetupPlan()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.setupPlan == nil || model.isExecutingSetup)
                .accessibilityIdentifier("onboarding-execute-setup-button")
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }
}

// MARK: - Step 5: Setup Transaction

struct OnboardingSetupTransactionStepView: View {
    @ObservedObject var model: WorkspacePresentationModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ProgressView()
                .controlSize(.large)

            VStack(spacing: 8) {
                Text("Configuring Selected Apps…")
                    .font(.title2.weight(.bold))

                if let progress = model.setupProgress {
                    if let currentTargetID = progress.currentTargetID {
                        Text("Target: \(currentTargetID.rawValue)")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(progress.completedCount) of \(progress.totalCount) apps completed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Establishing durable connection baselines…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Divider()

            HStack {
                Spacer()
                Button("Cancel Remaining") {
                    Task {
                        await model.cancelRemainingSetup()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.isCancellingRemainingSetup)
                .accessibilityIdentifier("onboarding-cancel-setup-button")
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }
}

// MARK: - Step 6: Setup Results

struct OnboardingSetupResultsStepView: View {
    @ObservedObject var model: WorkspacePresentationModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Setup Results")
                            .font(.title2.weight(.bold))
                        Text(summaryText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let report = model.latestSetupReport {
                        VStack(spacing: 12) {
                            ForEach(report.combinedOutcomes, id: \.targetInstanceID.rawValue) { outcome in
                                let kind = report.outcomeKind(for: outcome)
                                HStack(spacing: 12) {
                                    Image(systemName: outcomeIcon(kind))
                                        .font(.title3)
                                        .foregroundStyle(outcomeColor(kind))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(outcome.targetInstanceID.rawValue)
                                            .font(.headline)
                                        if let detail = outcome.detail {
                                            Text(detail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(kind.rawValue.capitalized)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(outcomeColor(kind))
                                }
                                .padding(12)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .padding(28)
            }

            Divider()

            HStack {
                if !model.workspace.connectedTargetInstances.isEmpty {
                    Button("Finish Setup") {
                        model.completeOnboarding()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding-finish-setup-button")

                    Spacer()

                    Button("Continue to Apply Theme") {
                        model.acknowledgeSetupResults()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding-continue-apply-button")
                } else {
                    Button("Set Up Later") {
                        model.deferOnboarding()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button("Back to Target Selection") {
                        model.acknowledgeSetupResults()
                        model.goToOnboardingStep(.targetOptIns)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("onboarding-back-to-targets-button")
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }

    private var summaryText: String {
        let connectedCount = model.workspace.connectedTargetInstances.count
        if connectedCount > 0 {
            return "\(connectedCount) target\(connectedCount == 1 ? "" : "s") successfully connected."
        } else {
            return "No targets were connected. You can adjust your selections or set up later."
        }
    }

    private func outcomeIcon(_ kind: SetupReport.OutcomeKind) -> String {
        switch kind {
        case .connected, .unchanged:
            return "checkmark.circle.fill"
        case .failed, .conflict, .recoveryRequired:
            return "exclamationmark.triangle.fill"
        case .skipped, .unavailable:
            return "slash.circle.fill"
        case .needsPermission:
            return "lock.fill"
        }
    }

    private func outcomeColor(_ kind: SetupReport.OutcomeKind) -> Color {
        switch kind {
        case .connected, .unchanged:
            return .green
        case .failed, .conflict, .recoveryRequired:
            return .red
        case .needsPermission:
            return .orange
        case .skipped, .unavailable:
            return .secondary
        }
    }
}

// MARK: - Step 7: Initial Apply

struct OnboardingInitialApplyStepView: View {
    @ObservedObject var model: WorkspacePresentationModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apply Your Theme")
                            .font(.title2.weight(.bold))
                        Text("Apply your desired theme across your connected applications.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let selectedVariantID = model.selectedThemeVariantID,
                       let variant = model.bundledThemeVariants.first(where: { $0.id == selectedVariantID }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Desired Theme: \(variant.preview.displayName)")
                                .font(.headline)
                            ThemeSwatchStrip(preview: variant.preview)
                                .frame(height: 24)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Connected Targets (\(model.workspace.connectedTargetInstances.count))")
                            .font(.headline)

                        ForEach(model.workspace.connectedTargetInstances, id: \.id.rawValue) { instance in
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(instance.displayName)
                                    .font(.body)
                                Spacer()
                                Text(instance.adapterID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.leading, 4)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    if model.isApplyingTheme {
                        HStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Applying theme to connected targets…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }

                    if let report = model.latestApplyReport {
                        HStack(spacing: 12) {
                            Image(systemName: reportNeedsAttention(report) ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                                .font(.title2)
                                .foregroundStyle(reportNeedsAttention(report) ? .orange : .green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reportNeedsAttention(report) ? "Theme Apply Needs Attention" : "Theme Applied Successfully!")
                                    .font(.headline)
                                Text(reportNeedsAttention(report) ? "Review the reported target issues before completing onboarding." : "All connected targets have been updated to your desired theme.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background((reportNeedsAttention(report) ? Color.orange : Color.green).opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(28)
            }

            Divider()

            HStack {
                if model.latestApplyReport.map(reportNeedsAttention) != false {
                    Spacer()
                    Button(model.latestApplyReport == nil ? "Apply Theme" : "Try Apply Again") {
                        Task {
                            if let plan = try? await model.prepareSelectedTheme() {
                                _ = try? await model.apply(planID: plan.id)
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isApplyingTheme || !model.canApplyThemes)
                    .accessibilityIdentifier("onboarding-apply-theme-button")
                } else {
                    Spacer()

                    Button("Done & Open Overview") {
                        model.completeOnboarding()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding-done-button")
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
    }

    private func reportNeedsAttention(_ report: DurableApplyReport) -> Bool {
        report.outcomes.contains { outcome in
            switch outcome.configurationState {
            case .permissionRequired, .conflicted, .failed:
                return true
            case .updated, .unchanged, .unavailable:
                return outcome.rollbackState == .recoveryRequired
            }
        }
    }
}
