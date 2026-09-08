import PlatformClients
import SwiftUI

struct SettingsView: View {
    @ObservedObject var presenceController: AppPresenceController

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
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 300)
        .task {
            presenceController.refreshLaunchAtLoginStatus()
            await presenceController.refreshNotificationPermissionStatus()
        }
    }
}
