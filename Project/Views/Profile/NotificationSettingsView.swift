//
//  NotificationSettingsView.swift
//  LootList
//
//  Created by Ben Mackin on 8/9/26.
//

import SwiftData
import SwiftUI
import UserNotifications

@MainActor
struct NotificationSettingsView: View {
    private let notificationService: NotificationService
    private let profile: Profile
    private let family: Family

    @Environment(ToastManager.self) private var toastManager

    @Query private var cachedPreferences: [NotificationPreferenceCache]

    @AppStorage("masterNotificationsEnabled") private var masterNotificationsEnabled = true

    /// Plays the celebration chime (and fires the success haptic) when a trophy
    /// or streak milestone unlocks. Defaults to on; surfaced here because this
    /// view is the canonical home for notification/sound toggles.
    @AppStorage("celebrationSoundEnabled") private var celebrationSoundEnabled = true

    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showClearedToast = false

    init(notificationService: NotificationService,
         profile: Profile,
         family: Family)
    {
        self.notificationService = notificationService
        self.profile = profile
        self.family = family

        let profileName = profile.id.recordName
        let familyName = family.id.recordName
        let filter = #Predicate<NotificationPreferenceCache> {
            $0.profileRecordName == profileName && $0.familyRecordName == familyName
        }
        _cachedPreferences = Query(filter: filter)
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
                                do {
                                    let granted = try await notificationService.requestAuthorization()
                                    await updateAuthStatus()
                                    if granted {
                                        notificationService.registerForRemoteNotifications()
                                    }
                                } catch {
                                    await updateAuthStatus()
                                    toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
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
                                    do {
                                        _ = try await notificationService.requestAuthorization()
                                    } catch {
                                        toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                                    }
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

            // MARK: - 2b. Celebration Sounds Section

            Section {
                Toggle("Celebration Sound", isOn: $celebrationSoundEnabled)
                    .tint(.accentColor)

                Text(celebrationSoundEnabled
                    ? "Plays a chime and haptic when a trophy or streak milestone is unlocked."
                    : "Trophy and streak milestone celebrations will be silent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Sounds")
            }

            // MARK: - 3. Grouped Event Toggles

            ForEach(NotificationCategory.allCases, id: \.self) { category in
                let events = NotificationEventType.allCases
                    .filter { $0.category == category }
                    .filter { profile.role.isParent ? $0.isRelevantForParent : $0.isRelevantForHero }

                if !events.isEmpty {
                    Section {
                        ForEach(events, id: \.self) { event in
                            Toggle(isOn: toggleBinding(for: event)) {
                                Label(event.displayName, systemImage: event.iconSystemName)
                            }
                            .disabled(!masterNotificationsEnabled)
                        }
                    } header: {
                        Text("\(category.icon) \(category.rawValue)")
                    } footer: {
                        Text(category.footer)
                    }
                }
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
                try? await Task.sleep(nanoseconds: DesignSystemConstants.AnimationDuration.toggleFeedbackNanos)
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
            get: {
                if let cached = cachedPreferences.first(where: { $0.eventType == event.rawValue }) {
                    return cached.enabled
                }
                return notificationService.isNotificationEnabled(for: event)
            },
            set: { newValue in
                Task {
                    do {
                        try await notificationService.updatePreference(event: event, enabled: newValue)
                        UserDefaults.standard.set(newValue, forKey: event.userDefaultsKey)
                    } catch {
                        toastManager.show(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, type: .error)
                    }
                }
            }
        )
    }
}
