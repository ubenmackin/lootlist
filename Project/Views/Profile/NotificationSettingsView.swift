//
//  NotificationSettingsView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI
import UserNotifications

@MainActor
struct NotificationSettingsView: View {
    private let notificationService: NotificationService
    private let profile: Profile
    private let family: Family

    @AppStorage("masterNotificationsEnabled") private var masterNotificationsEnabled = true

    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showClearedToast = false

    init(notificationService: NotificationService,
         profile: Profile,
         family: Family)
    {
        self.notificationService = notificationService
        self.profile = profile
        self.family = family
    }

    var body: some View {
        Form {
            // MARK: - 1. Authorization Status Section

            Section {
                HStack(spacing: 14) {
                    Image(systemName: statusIcon)
                        .font(.title2)
                        .foregroundStyle(statusColor)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Notification Status")
                            .font(.headline)

                        Text(statusText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if authorizationStatus == .notDetermined {
                        Button("Enable") {
                            Task {
                                let granted = await (try? notificationService.requestAuthorization()) ?? false
                                await updateAuthStatus()
                                if granted {
                                    notificationService.registerForRemoteNotifications()
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Authorization")
            } footer: {
                if authorizationStatus == .denied {
                    Text("Notifications are blocked in System Settings. Go to iOS Settings > LootList > Notifications to enable alerts.")
                }
            }

            // MARK: - 2. Master Toggle Section

            Section {
                Toggle("Allow Push Notifications", isOn: $masterNotificationsEnabled)
                    .tint(.accentColor)
                    .onChange(of: masterNotificationsEnabled) { _, newValue in
                        if newValue {
                            if authorizationStatus == .notDetermined {
                                Task {
                                    _ = try? await notificationService.requestAuthorization()
                                    await updateAuthStatus()
                                }
                            }
                        } else {
                            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                        }
                    }

                Text(masterNotificationsEnabled
                    ? "Individual event types can be controlled below."
                    : "All notifications are disabled when this master toggle is off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Master Toggle")
            }

            // MARK: - 3. Individual Event Sub-Toggles

            //
            // Per-event toggles write-through optimistically to the
            // `NotificationPreferenceCache` + CloudKit via
            // `NotificationService.updatePreference(event:enabled:)`.
            // The `UserDefaults` mirror write inside the setter preserves the
            // first-launch fallback. The master toggle above remains a
            // device-level authorization gate (not a synced preference).

            Section {
                Toggle(isOn: toggleBinding(for: .questAssigned)) {
                    Label("Quest Assignments", systemImage: "scroll.fill")
                }
                .disabled(!masterNotificationsEnabled)

                Toggle(isOn: toggleBinding(for: .questNeedsReview)) {
                    Label("Quest Approvals", systemImage: "checkmark.shield.fill")
                }
                .disabled(!masterNotificationsEnabled)

                Toggle(isOn: toggleBinding(for: .questCompleted)) {
                    Label("Quest Verification Alerts", systemImage: "seal.fill")
                }
                .disabled(!masterNotificationsEnabled)

                Toggle(isOn: toggleBinding(for: .levelUp)) {
                    Label("Level Up Alerts", systemImage: "star.fill")
                }
                .disabled(!masterNotificationsEnabled)

                Toggle(isOn: toggleBinding(for: .goldEarned)) {
                    Label("Sunday Loot Day Payouts", systemImage: "circle.hexagongrid.fill")
                }
                .disabled(!masterNotificationsEnabled)
            } header: {
                Text("Event Alerts")
            } footer: {
                Text("Choose which specific events send push notifications when master alerts are allowed.")
            }

            // MARK: - 4. Actions Section

            Section {
                Button(role: .destructive) {
                    UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
                    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
                    withAnimation { showClearedToast = true }
                } label: {
                    Label("Clear All Pending Notifications", systemImage: "trash")
                }
            } footer: {
                if showClearedToast {
                    Text("Cleared all pending and delivered notifications.")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await updateAuthStatus()
        }
        .task(id: showClearedToast) {
            if showClearedToast {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                showClearedToast = false
            }
        }
    }

    private var statusIcon: String {
        switch authorizationStatus {
        case .authorized, .provisional: "bell.badge.fill"
        case .denied: "bell.slash.fill"
        case .notDetermined: "bell.fill"
        case .ephemeral: "bell.fill"
        @unknown default: "bell.fill"
        }
    }

    private var statusColor: Color {
        switch authorizationStatus {
        case .authorized, .provisional: .green
        case .denied: .red
        case .notDetermined: .orange
        case .ephemeral: .green
        @unknown default: .gray
        }
    }

    private var statusText: String {
        switch authorizationStatus {
        case .authorized, .provisional: "Authorized in iOS"
        case .denied: "Denied in System Settings"
        case .notDetermined: "Authorization Not Requested"
        case .ephemeral: "Provisional Authorized"
        @unknown default: "Status Unknown"
        }
    }

    @MainActor
    private func updateAuthStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    private func toggleBinding(for event: NotificationEventType) -> Binding<Bool> {
        Binding<Bool>(
            get: { notificationService.isNotificationEnabled(for: event) },
            set: { newValue in
                // Mirror to UserDefaults for first-launch fallback continuity.
                UserDefaults.standard.set(newValue, forKey: event.userDefaultsKey)
                Task {
                    try? await notificationService.updatePreference(event: event, enabled: newValue)
                }
            }
        )
    }
}
