//
//  SettingsView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(NotificationService.self) private var notificationService
    @Environment(FamilyService.self) private var familyService
    @Environment(CKSyncEngineCoordinator.self) private var syncCoordinator: CKSyncEngineCoordinator?

    @AppStorage("preferredAppearance") private var preferredAppearance: String = "system"

    var body: some View {
        NavigationStack {
            List {
                // Section 1: Guild Management
                Section("Guild Management") {
                    NavigationLink {
                        GuildSettingsView(familyRecordName: appState.family?.id.recordName)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Guild Settings")
                                    .font(.body.weight(.semibold))
                                Text("Family name, roles, invitations, data reset")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "house.fill")
                                .foregroundStyle(.purple)
                        }
                    }
                }

                Section("iCloud Sync") {
                    NavigationLink {
                        iCloudStatusView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("iCloud Sync")
                                    .font(.body.weight(.semibold))
                                Text(syncStatusText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "cloud.fill")
                                .foregroundStyle(.blue)
                        }
                    }
                }

                // Section 3: Preferences
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

                // Section: Developer Tools
                Section("Developer") {
                    NavigationLink {
                        SpriteGalleryView()
                    } label: {
                        Label("Sprite Gallery", systemImage: "square.grid.2x2.fill")
                            .foregroundStyle(.indigo)
                    }
                }

                // Section 4: App Information
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
                        Text("\(Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "LootList") for Families")
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

    private var syncStatusText: String {
        if syncCoordinator?.syncError != nil {
            "Sync failed — tap to retry"
        } else if syncCoordinator?.isSyncing == true {
            "Syncing…"
        } else if (syncCoordinator?.pendingUploadCount ?? 0) > 0 {
            "\(syncCoordinator?.pendingUploadCount ?? 0) pending upload\(syncCoordinator?.pendingUploadCount == 1 ? "" : "s")"
        } else if let last = syncCoordinator?.lastSyncedAt {
            "Last synced \(last.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"
        } else if syncCoordinator == nil {
            "Unavailable"
        } else {
            "Not yet synced"
        }
    }

    private var colorScheme: ColorScheme? {
        switch preferredAppearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}
