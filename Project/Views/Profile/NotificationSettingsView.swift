import SwiftUI
import CloudKit

@MainActor
struct NotificationSettingsView: View {

    private let notificationService: NotificationService

    private let profile: Profile

    private let family: Family

    @State private var preferences: [NotificationEventType: NotificationPreference] = [:]

    @State private var isLoading = false

    @State private var loadError: String?

    init(notificationService: NotificationService,
         profile: Profile,
         family: Family) {
        self.notificationService = notificationService
        self.profile = profile
        self.family = family
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose which alerts reach you. Each event has an in-app **Enabled** toggle and a separate **Push** toggle so you can decide exactly what reaches your lock screen.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Event Types") {
                    if isLoading && preferences.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .frame(minHeight: 80)
                    } else {
                        ForEach(NotificationEventType.allCases, id: \.self) { eventType in
                            row(for: eventType)
                        }
                    }
                }

                if let loadError {
                    Section {
                        Text(loadError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await refresh() }
            .task { await refresh() }
        }
    }

    @ViewBuilder
    private func row(for eventType: NotificationEventType) -> some View {
        let preference = preferences[eventType]
        NotificationToggleRow(
            eventType: eventType,
            enabled: preference?.enabled ?? false,
            pushEnabled: preference?.pushEnabled ?? false,
            onEnabledChange: { newValue in
                handleChange(enabled: newValue,
                              pushEnabled: nil,
                              for: eventType)
            },
            onPushEnabledChange: { newValue in
                handleChange(enabled: nil,
                              pushEnabled: newValue,
                              for: eventType)
            }
        )
    }

    private func handleChange(enabled: Bool?,
                                pushEnabled: Bool?,
                                for eventType: NotificationEventType) {

        let previous = preferences[eventType]

        if var preference = preferences[eventType] {
            if let enabled { preference.enabled = enabled }
            if let pushEnabled { preference.pushEnabled = pushEnabled }
            preferences[eventType] = preference
        }

        let newEnabled = enabled ?? previous?.enabled ?? false
        let newPush = pushEnabled ?? previous?.pushEnabled ?? false

        Task { @MainActor in
            do {
                try await notificationService.setEnabled(
                    newEnabled,
                    pushEnabled: newPush,
                    for: eventType,
                    profile: profile)
                loadError = nil
            } catch {

                if let previous {
                    preferences[eventType] = previous
                } else {
                    preferences.removeValue(forKey: eventType)
                }
                loadError = "Could not save preference: \(error.localizedDescription)"
            }
        }
    }

    @MainActor private func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            try await notificationService.ensureDefaultPreferences(
                profile: profile,
                role: profile.role,
                family: family)
            let fetched = try await notificationService.fetchPreferences(profile: profile)
            preferences = fetched
            loadError = nil
        } catch {
            loadError = "Could not load preferences: \(error.localizedDescription)"
        }
    }
}
