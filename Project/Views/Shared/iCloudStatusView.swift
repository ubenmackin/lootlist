//
//  iCloudStatusView.swift
//  LootList
//
//  Created by Ben Mackin on 7/26/26.
//

import CloudKit
import SwiftData
import SwiftUI

struct iCloudStatusView: View {
    @Environment(AppState.self) private var appState
    @Environment(SyncEngine.self) private var syncEngine: SyncEngine?

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
        if syncEngine?.syncError != nil {
            return "Failed"
        }
        if syncEngine?.isSyncing == true {
            return "Syncing"
        }
        if syncEngine?.lastSyncedAt == nil {
            return "Pending"
        }
        return "Synced"
    }

    private var syncStatusColor: Color {
        switch syncStatusLabel {
        case "Failed": .red
        case "Syncing": .blue
        case "Pending": .orange
        case "Synced": .green
        default: .secondary
        }
    }

    private var lastSyncedText: String {
        guard let lastSyncedAt = syncEngine?.lastSyncedAt else {
            return "Never synced"
        }
        return lastSyncedAt.formatted(.relative(presentation: .named))
    }

    // MARK: Body

    var body: some View {
        List {
            syncStatusSection
            recordCountsSection
            cloudKitAccountSection
            actionsSection
        }
        .navigationTitle("iCloud Status")
        .navigationBarTitleDisplayMode(.large)
        .task {
            await fetchAccountStatus()
        }
    }

    // MARK: Section 1 — Sync Status

    private var syncStatusSection: some View {
        Section {
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

            if let error = syncEngine?.syncError {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
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
        case "Pending": "clock.fill"
        case "Synced": "checkmark.circle.fill"
        default: "questionmark.circle.fill"
        }
    }

    // MARK: Section 2 — Record Counts

    private var recordCountsSection: some View {
        Section("Record Counts") {
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

    // MARK: Section 3 — CloudKit Account

    private var cloudKitAccountSection: some View {
        Section("CloudKit Account") {
            HStack {
                Text("Account")
                Spacer()
                if let error = accountStatusError {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                } else {
                    Text(accountStatus.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(accountStatusColor(accountStatus))
                }
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

    // MARK: Section 4 — Actions

    private var actionsSection: some View {
        Section {
            Button {
                Task { await syncEngine?.syncAll() }
            } label: {
                HStack {
                    Label("Force Sync", systemImage: "arrow.triangle.2.circlepath")
                    if syncEngine?.isSyncing == true {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(syncEngine?.isSyncing == true)

            if let lastSyncedAt = syncEngine?.lastSyncedAt {
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
        } catch {
            accountStatusError = error.localizedDescription
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
