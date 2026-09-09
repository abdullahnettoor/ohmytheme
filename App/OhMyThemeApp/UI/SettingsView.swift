import PlatformClients
import SwiftUI
import ThemeEngine
import ThemeModel

struct SettingsView: View {
    @ObservedObject var presenceController: AppPresenceController
    @ObservedObject var model: WorkspacePresentationModel
    @State private var confirmsCompleteReset = false
    @State private var pendingRelinquishTarget: TargetInstanceID?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "Show menu bar item",
                        isOn: presenceController.isMenuBarVisibleBinding
                    )
                    .disabled(presenceController.isChangingAppPresencePreference)
                    .accessibilityIdentifier("settings-menu-bar-toggle")

                    if let error = presenceController.menuBarVisibilityError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings-menu-bar-error")
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "Launch at login",
                        isOn: Binding(
                            get: { presenceController.isLaunchAtLoginSelected },
                            set: { newValue in
                                Task {
                                    try? await presenceController.setLaunchAtLoginEnabled(newValue)
                                }
                            }
                        )
                    )
                    .disabled(
                        !presenceController.isLaunchAtLoginEligible
                            || presenceController.isChangingAppPresencePreference
                    )
                    .accessibilityIdentifier("settings-launch-at-login-toggle")

                    if let explanation = presenceController.launchAtLoginExplanation {
                        Text(explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings-launch-at-login-explanation")
                    }

                    if let error = presenceController.launchAtLoginError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("settings-launch-at-login-error")
                    }
                }
            } header: {
                Text("General")
            }

            Section {
                LabeledContent("Notifications") {
                    Text(presenceController.notificationPermissionStatus.rawValue)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("settings-notifications-status")
            } header: {
                Text("Permissions")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "Restores every managed Target, then clears opt-ins, theme choice, onboarding state, recovery data, preferences, and Launch at Login before quitting."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Button("Reset Oh My Theme…", role: .destructive) {
                        confirmsCompleteReset = false
                        pendingRelinquishTarget = nil
                        model.perform {
                            try await model.reviewReset()
                        }
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("settings-reset-button")
                }
            } header: {
                Text("Reset")
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.resetReview != nil },
                set: { isPresented in
                    if !isPresented {
                        model.dismissResetReview()
                        confirmsCompleteReset = false
                        pendingRelinquishTarget = nil
                    }
                }
            )
        ) {
            if let review = model.resetReview {
                resetReviewSheet(review)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 300)
        .task {
            presenceController.refreshLaunchAtLoginStatus()
            await presenceController.refreshNotificationPermissionStatus()
        }
    }

    private func resetReviewSheet(_ review: ResetReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reset Oh My Theme")
                .font(.headline)
                .accessibilityIdentifier("reset-review-title")
            Text(
                "Every connected Target must reach a safe terminal state first. "
                    + "Safe Targets restore their Connection Baseline. Conflicting Targets need explicit relinquishment or stay unresolved and block Reset."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if review.entries.isEmpty {
                Label(
                    "No connected Targets. Reset will clear opt-ins, theme choice, onboarding state, recovery data, preferences, and Launch at Login, then quit.",
                    systemImage: "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("reset-review-empty")
            } else {
                ForEach(review.entries, id: \.targetInstanceID) { entry in
                    resetEntryRow(entry)
                }
            }

            if let operationError = model.operationError {
                Text(operationError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("reset-review-error")
            }

            HStack(spacing: 10) {
                Button("Cancel", role: .cancel) {
                    model.dismissResetReview()
                    confirmsCompleteReset = false
                    pendingRelinquishTarget = nil
                }
                Spacer()
                if confirmsCompleteReset {
                    Button("Complete Reset and Quit", role: .destructive) {
                        model.perform {
                            try await model.finalizeResetAndQuit()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy || !review.canComplete)
                    .accessibilityIdentifier("confirm-complete-reset")
                } else {
                    Button("Review Complete Reset…") {
                        confirmsCompleteReset = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(!review.canComplete)
                    .accessibilityIdentifier("review-complete-reset-button")
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    private func resetEntryRow(_ entry: DisconnectReview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.targetInstanceID.rawValue)
                .font(.callout.weight(.medium))
            if entry.isSafeToRestore {
                Label("Safe to restore", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                ForEach(entry.expectedEffects, id: \.self) { effect in
                    Text(effect)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !entry.residualPathsIfRelinquished.isEmpty {
                    Text("If relinquished instead, these remain in place:")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(entry.residualPathsIfRelinquished, id: \.self) { path in
                        Text(path)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button("Restore and Disconnect") {
                    pendingRelinquishTarget = nil
                    model.perform {
                        try await model.restoreAndDisconnect(entry.targetInstanceID)
                        try await model.reviewReset()
                    }
                }
                .controlSize(.small)
                .disabled(model.isBusy)
                .accessibilityIdentifier("reset-restore-\(entry.targetInstanceID.rawValue)")
            } else {
                Label(
                    "External change detected: \(entry.conflictDetail ?? "conflict")",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("reset-conflict-\(entry.targetInstanceID.rawValue)")
                ForEach(entry.residualPathsIfRelinquished, id: \.self) { path in
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if pendingRelinquishTarget == entry.targetInstanceID {
                    Button("Relinquish and Keep Files", role: .destructive) {
                        pendingRelinquishTarget = nil
                        model.perform {
                            try await model.relinquishManagement(entry.targetInstanceID)
                            try await model.reviewReset()
                        }
                    }
                    .controlSize(.small)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("reset-relinquish-\(entry.targetInstanceID.rawValue)")
                } else {
                    Button("Review Relinquishment…", role: .destructive) {
                        pendingRelinquishTarget = entry.targetInstanceID
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("reset-review-relinquishment-\(entry.targetInstanceID.rawValue)")
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("reset-entry-\(entry.targetInstanceID.rawValue)")
    }
}
