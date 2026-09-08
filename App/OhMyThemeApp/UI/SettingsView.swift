import SwiftUI
import PlatformClients

struct SettingsView: View {
    @ObservedObject var presenceController: AppPresenceController

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Show menu bar item",
                    isOn: presenceController.isMenuBarVisibleBinding
                )
                .accessibilityIdentifier("settings-menu-bar-toggle")

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "Launch at login",
                        isOn: Binding(
                            get: { presenceController.launchAtLoginStatus == .enabled },
                            set: { newValue in
                                Task {
                                    try? await presenceController.setLaunchAtLoginEnabled(newValue)
                                }
                            }
                        )
                    )
                    .disabled(!presenceController.isLaunchAtLoginEligible)
                    .accessibilityIdentifier("settings-launch-at-login-toggle")

                    if let explanation = presenceController.launchAtLoginExplanation {
                        Text(explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings-launch-at-login-explanation")
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
        .frame(width: 460, height: 260)
    }
}
