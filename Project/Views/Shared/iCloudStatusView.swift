//
//  iCloudStatusView.swift
//  LootList
//
//  Created by Ben Mackin on 7/26/26.
//

import CloudKit
import os
import SwiftData
import SwiftUI

struct iCloudStatusView: View {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "iCloudStatus")

    @Environment(AppState.self) private var appState
    @Environment(CKSyncEngineCoordinator.self) private var syncCoordinator: CKSyncEngineCoordinator?
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?
    @Environment(NetworkMonitor.self) private var networkMonitor: NetworkMonitor?
    @Environment(ToastManager.self) private var toastManager: ToastManager?

    // iCloudStatusView intentionally omits familyRecordName filters on all @Query
    // declarations. This view is the diagnostic panel that surfaces ALL cached
    // rows across every family — including abandoned ones — for iCloud
    // troubleshooting. DO NOT add family predicates here.

    @Query(sort: \ProfileCache.displayName) private var allProfiles: [ProfileCache]
    @Query(sort: \QuestCache.weekOf) private var allQuests: [QuestCache]
    @Query(sort: \QuestTemplateCache.name) private var allTemplates: [QuestTemplateCache]
    @Query(sort: \QuestCompletionCache.completedDate) private var allCompletions: [QuestCompletionCache]
    @Query(sort: \AllowancePeriodCache.weekOf) private var allAllowancePeriods: [AllowancePeriodCache]
    @Query(sort: \LedgerEntryCache.date) private var allLedgerEntries: [LedgerEntryCache]
    @Query(sort: \AchievementCache.name) private var allAchievements: [AchievementCache]
    @Query(sort: \ProfileAchievementCache.earnedDate) private var allProfileAchievements: [ProfileAchievementCache]
    @Query(sort: \NotificationPreferenceCache.profileRecordName) private var allNotificationPrefs: [NotificationPreferenceCache]
    @Query(sort: \FamilyCache.name) private var allFamilies: [FamilyCache]

    @State private var accountStatus: CKAccountStatus = .couldNotDetermine
    @State private var accountStatusError: String?

    private var familyRecordName: String? {
        appState.family?.id.recordName
    }

    // MARK: - Filtered Record Counts

    private var profileCount: Int {
        guard let family = familyRecordName else { return 0 }
        return allProfiles.filter { $0.familyRecordName == family }.count
    }

    private var questCount: Int {
        guard let family = familyRecordName else { return 0 }
        return allQuests.filter { $0.familyRecordName == family }.count
    }

    private var templateCount: Int {
        guard let family = familyRecordName else { return 0 }
        return allTemplates.filter { $0.familyRecordName == family }.count
    }

    private var completionCount: Int {
        guard let family = familyRecordName else { return 0 }
        return allCompletions.filter { $0.familyRecordName == family }.count
    }

    private var allowancePeriodCount: Int {
        guard let family = familyRecordName else { return 0 }
        return allAllowancePeriods.filter { $0.familyRecordName == family }.count
    }

    private var ledgerEntryCount: Int {
        guard let family = familyRecordName else { return 0 }
        return allLedgerEntries.filter { $0.familyRecordName == family }.count
    }

    private var achievementCount: Int {
        guard let family = familyRecordName else { return 0 }
        return allAchievements.filter { $0.familyRecordName == family }.count
    }

    private var profileAchievementCount: Int {
        guard let family = familyRecordName else { return 0 }
        return allProfileAchievements.filter { $0.familyRecordName == family }.count
    }

    private var notificationPrefCount: Int {
        guard let family = familyRecordName else { return 0 }
        return allNotificationPrefs.filter { $0.familyRecordName == family }.count
    }

    /// FamilyCache uses `recordName` as its family identifier—it does not have a `familyRecordName` field.
    private var familyCount: Int {
        guard let family = familyRecordName else { return 0 }
        return allFamilies.filter { $0.recordName == family }.count
    }

    // MARK: Sync Status

    private var syncStatusLabel: String {
        if syncCoordinator?.syncError != nil {
            return "Failed"
        }
        if syncCoordinator?.isSyncing == true {
            return "Syncing"
        }
        if (syncCoordinator?.pendingUploadCount ?? 0) > 0 {
            return "Pending Uploads"
        }
        if syncCoordinator?.lastSyncedAt == nil {
            return "Pending"
        }
        return "Synced"
    }

    private var syncStatusColor: Color {
        switch syncStatusLabel {
        case "Failed": .red
        case "Syncing": .blue
        case "Pending Uploads", "Pending": .orange
        case "Synced": .green
        default: .secondary
        }
    }

    private var lastSyncedText: String {
        guard let lastSyncedAt = syncCoordinator?.lastSyncedAt else {
            return "Never synced"
        }
        return lastSyncedAt.formatted(.relative(presentation: .named))
    }

    // MARK: Body

    var body: some View {
        List {
            syncStatusSection
            networkSection
            recordCountsSection
            cloudKitAccountSection
            actionsSection
        }
        .navigationTitle("iCloud Status")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await fetchAccountStatus()
        }
        .onChange(of: syncCoordinator?.syncError) { _, newError in
            if let newError, !newError.isEmpty {
                toastManager?.show(message: newError, type: .error)
            }
        }
    }

    // MARK: Section 1 — Sync Status

    private var syncStatusSection: some View {
        Section("CKSyncEngine Status") {
            HStack {
                Text("Status")
                Spacer()
                Label(syncStatusLabel, systemImage: syncStatusIcon)
                    .font(.caption.bold())
                    .foregroundStyle(syncStatusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(syncStatusColor.opacity(0.15))
                    )
            }

            HStack {
                Text("Pending Uploads")
                Spacer()
                Text("\(syncCoordinator?.pendingUploadCount ?? 0)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle((syncCoordinator?.pendingUploadCount ?? 0) > 0 ? Color.orange : Color.secondary)
            }

            HStack {
                Text("Last Synced")
                Spacer()
                Text(lastSyncedText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var syncStatusIcon: String {
        switch syncStatusLabel {
        case "Failed": "xmark.circle.fill"
        case "Syncing": "arrow.triangle.2.circlepath"
        case "Pending Uploads": "arrow.up.circle.fill"
        case "Pending": "clock.fill"
        case "Synced": "checkmark.circle.fill"
        default: "questionmark.circle.fill"
        }
    }

    // MARK: Section 2 — Network Reachability

    private var networkSection: some View {
        Section("Network Connectivity") {
            HStack {
                Text("Connection")
                Spacer()
                if let monitor = networkMonitor {
                    Label(monitor.connectionType.displayName, systemImage: monitor.connectionType.iconName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(monitor.isConnected ? Color.green : Color.red)
                } else {
                    Text("Unknown")
                        .foregroundStyle(.secondary)
                }
            }

            if let monitor = networkMonitor, monitor.isConnected {
                if monitor.isConstrained {
                    HStack {
                        Text("Low Data Mode")
                        Spacer()
                        Text("Enabled")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
                if monitor.isExpensive {
                    HStack {
                        Text("Cellular / Metered")
                        Spacer()
                        Text("Active")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Section 3 — Record Counts

    private var recordCountsSection: some View {
        Section("Cached Record Counts") {
            countRow(label: "Profiles", count: profileCount)
            countRow(label: "Quests", count: questCount)
            countRow(label: "Quest Templates", count: templateCount)
            countRow(label: "Quest Completions", count: completionCount)
            countRow(label: "Allowance Periods", count: allowancePeriodCount)
            countRow(label: "Ledger Entries", count: ledgerEntryCount)
            countRow(label: "Achievements", count: achievementCount)
            countRow(label: "Profile Achievements", count: profileAchievementCount)
            countRow(label: "Notification Prefs", count: notificationPrefCount)
            countRow(label: "Families", count: familyCount)
        }
    }

    private func countRow(label: String, count: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.12))
                )
        }
    }

    // MARK: Section 4 — CloudKit Account

    private var cloudKitAccountSection: some View {
        Section("iCloud Account") {
            HStack {
                Text("Account Status")
                Spacer()
                Text(accountStatus.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(accountStatusColor(accountStatus))
            }
        }
    }

    private func accountStatusColor(_ status: CKAccountStatus) -> Color {
        switch status {
        case .available: return .green
        case .noAccount: return .orange
        case .restricted: return .red
        case .temporarilyUnavailable: return .yellow
        case .couldNotDetermine: return .secondary
        @unknown default: return .secondary
        }
    }

    // MARK: Section 5 — Actions

    private var actionsSection: some View {
        Section {
            Button {
                Task {
                    await lifecycleCoordinator?.performManualSync()
                }
            } label: {
                HStack {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    if syncCoordinator?.isSyncing == true {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(syncCoordinator?.isSyncing == true)

            if let lastSyncedAt = syncCoordinator?.lastSyncedAt {
                Text("Last synced \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: — CloudKit Helpers

    private func fetchAccountStatus() async {
        let container = CloudKitService.defaultContainer
        do {
            let status = try await container.accountStatus()
            accountStatus = status
            accountStatusError = nil
        } catch {
            logger.error("Failed to fetch iCloud account status: \(error, privacy: .private)")
            accountStatusError = "Could not check your iCloud account status. Please try again."
            toastManager?.show(message: "Could not check your iCloud account status. Please try again.", type: .error)
        }
    }
}

// MARK: - CKAccountStatus Display Name

private extension CKAccountStatus {
    var displayName: String {
        switch self {
        case .available: return "Available"
        case .noAccount: return "No Account"
        case .restricted: return "Restricted"
        case .couldNotDetermine: return "Could Not Determine"
        case .temporarilyUnavailable: return "Temporarily Unavailable"
        @unknown default: return "Unknown"
        }
    }
}
