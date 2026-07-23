import CloudKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(NotificationService.self) private var notificationService
    @Environment(FamilyService.self) private var familyService

    @AppStorage("preferredAppearance") private var preferredAppearance: String = "system"

    var body: some View {
        NavigationStack {
            List {
                // Section 1: Guild Management
                Section("Guild Management") {
                    NavigationLink {
                        GuildSettingsView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Guild Settings")
                                    .font(.body.weight(.semibold))
                                Text("Family name, roles, invite code, disband")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "house.fill")
                                .foregroundStyle(.purple)
                        }
                    }
                }

                // Section 2: Preferences
                Section("Preferences") {
                    // Appearance (Dark / Light / System)
                    Picker(selection: $preferredAppearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    } label: {
                        Label("Appearance", systemImage: "paintbrush.fill")
                            .foregroundStyle(.orange)
                    }

                    // Notifications
                    if let profile = appState.currentProfile, let family = appState.family {
                        NavigationLink {
                            NotificationSettingsView(
                                notificationService: notificationService,
                                profile: profile,
                                family: family
                            )
                        } label: {
                            Label("Notifications", systemImage: "bell.badge.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }

                // Section 3: App Information
                Section("About") {
                    HStack {
                        Label("Version", systemImage: "info.circle.fill")
                            .foregroundStyle(.blue)
                        Spacer()
                        Text(appVersionString)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Realm", systemImage: "shield.fill")
                            .foregroundStyle(.yellow)
                        Spacer()
                        Text("QuestLog for Families")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
        .preferredColorScheme(colorScheme)
    }

    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var colorScheme: ColorScheme? {
        switch preferredAppearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}
