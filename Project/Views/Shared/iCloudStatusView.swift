//
//  iCloudStatusView.swift
//  LootList
//
//  Created by Ben Mackin on 7/26/26.
//

import SwiftData
import SwiftUI

#if DEBUG
    struct iCloudStatusView: View {
        @Environment(AppState.self) private var appState
        @Environment(CKSyncEngineCoordinator.self) private var syncCoordinator: CKSyncEngineCoordinator?
        @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?
        @Environment(NetworkMonitor.self) private var networkMonitor: NetworkMonitor?
        @Environment(ToastManager.self) private var toastManager: ToastManager?

        private let familyRecordName: String?

        @Query private var allProfiles: [ProfileCache]
        @Query private var allQuests: [QuestCache]
        @Query private var allTemplates: [QuestTemplateCache]
        @Query private var allCompletions: [QuestCompletionCache]
        @Query private var allAllowancePeriods: [AllowancePeriodCache]
        @Query private var allLedgerEntries: [LedgerEntryCache]
        @Query private var allAchievements: [AchievementCache]
        @Query private var allProfileAchievements: [ProfileAchievementCache]
        @Query private var allNotificationPrefs: [NotificationPreferenceCache]
        @Query private var allFamilies: [FamilyCache]
        @Query private var allGoals: [GoalCache]
        @Query private var allGemLedgers: [GemLedgerCache]
        @Query private var allRewardEvents: [RewardEventCache]

        // WHY: value mirror of CKAccountStatus published by the lifecycle
        // layer — views must not hold CloudKit types or call the service.
        private var accountStatus: CloudAccountStatus {
            appState.cloudAccountStatus
        }

        init(familyRecordName: String? = nil) {
            self.familyRecordName = familyRecordName

            // Scope every query to the active family at the SwiftData store layer.
            // When familyRecordName is nil, scope to "" so zero rows return rather than
            // leaking cross-family rows into a multifamily device.
            let targetFamily = familyRecordName ?? ""
            let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
            let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily }
            let templateFilter = #Predicate<QuestTemplateCache> { $0.familyRecordName == targetFamily }
            let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily }
            let allowanceFilter = #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily }
            let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
            let achievementFilter = #Predicate<AchievementCache> { $0.familyRecordName == targetFamily }
            let profileAchievementFilter = #Predicate<ProfileAchievementCache> { $0.familyRecordName == targetFamily }
            let notificationFilter = #Predicate<NotificationPreferenceCache> { $0.familyRecordName == targetFamily }
            let familyFilter = #Predicate<FamilyCache> { $0.recordName == targetFamily }
            let goalFilter = #Predicate<GoalCache> { $0.familyRecordName == targetFamily }
            let gemLedgerFilter = #Predicate<GemLedgerCache> { $0.familyRecordName == targetFamily }
            let rewardEventFilter = #Predicate<RewardEventCache> { $0.familyRecordName == targetFamily }

            _allProfiles = Query(filter: profileFilter, sort: \ProfileCache.displayName)
            _allQuests = Query(filter: questFilter, sort: \QuestCache.weekOf)
            _allTemplates = Query(filter: templateFilter, sort: \QuestTemplateCache.name)
            _allCompletions = Query(filter: completionFilter, sort: \QuestCompletionCache.completedDate)
            _allAllowancePeriods = Query(filter: allowanceFilter, sort: \AllowancePeriodCache.weekOf)
            _allLedgerEntries = Query(filter: ledgerFilter, sort: \LedgerEntryCache.date)
            _allAchievements = Query(filter: achievementFilter, sort: \AchievementCache.name)
            _allProfileAchievements = Query(filter: profileAchievementFilter, sort: \ProfileAchievementCache.earnedDate)
            _allNotificationPrefs = Query(filter: notificationFilter, sort: \NotificationPreferenceCache.profileRecordName)
            _allFamilies = Query(filter: familyFilter, sort: \FamilyCache.name)
            _allGoals = Query(filter: goalFilter, sort: \GoalCache.createdAt)
            _allGemLedgers = Query(filter: gemLedgerFilter, sort: \GemLedgerCache.createdAt)
            _allRewardEvents = Query(filter: rewardEventFilter, sort: \RewardEventCache.timestamp)
        }

        // MARK: - Filtered Record Counts

        /// Queries are already scoped to the active family, so counts are direct.
        private var profileCount: Int {
            allProfiles.count
        }

        private var questCount: Int {
            allQuests.count
        }

        private var templateCount: Int {
            allTemplates.count
        }

        private var completionCount: Int {
            allCompletions.count
        }

        private var allowancePeriodCount: Int {
            allAllowancePeriods.count
        }

        private var ledgerEntryCount: Int {
            allLedgerEntries.count
        }

        private var achievementCount: Int {
            allAchievements.count
        }

        private var profileAchievementCount: Int {
            allProfileAchievements.count
        }

        private var notificationPrefCount: Int {
            allNotificationPrefs.count
        }

        private var familyCount: Int {
            allFamilies.count
        }

        private var goalCount: Int {
            allGoals.count
        }

        private var gemLedgerCount: Int {
            allGemLedgers.count
        }

        private var rewardEventCount: Int {
            allRewardEvents.count
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
            case "Failed": Color(DesignSystemConstants.Colors.dangerRed)
            case "Syncing": Color(DesignSystemConstants.Colors.accentBlue)
            case "Pending Uploads", "Pending": Color(DesignSystemConstants.Colors.pendingAmber)
            case "Synced": Color(DesignSystemConstants.Colors.primaryGreen)
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
                await refreshAccountStatus()
            }
            .onChange(of: syncCoordinator?.syncError) { _, newError in
                if let newError, !newError.isEmpty {
                    toastManager?.show(message: newError, type: .error)
                }
            }
        }

        // MARK: Section 1 — Sync Status

        private var syncStatusSection: some View {
            Section("Sync Status") {
                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: syncStatusIcon)
                        Text(syncStatusLabel)
                    }
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
                        .foregroundStyle((syncCoordinator?.pendingUploadCount ?? 0) > 0 ? Color(DesignSystemConstants.Colors.pendingAmber) : Color.secondary)
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
                        HStack(spacing: 4) {
                            Image(systemName: monitor.connectionType.iconName)
                            Text(monitor.connectionType.displayName)
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(monitor.isConnected ? Color(DesignSystemConstants.Colors.primaryGreen) : Color(DesignSystemConstants.Colors.dangerRed))
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
                                .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
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
                countRow(label: "Goals", count: goalCount)
                countRow(label: "Achievements", count: achievementCount)
                countRow(label: "Profile Achievements", count: profileAchievementCount)
                countRow(label: "Notification Prefs", count: notificationPrefCount)
                countRow(label: "Gem Ledgers", count: gemLedgerCount)
                countRow(label: "Reward Events", count: rewardEventCount)
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

        private func accountStatusColor(_ status: CloudAccountStatus) -> Color {
            switch status {
            case .available: return Color(DesignSystemConstants.Colors.primaryGreen)
            case .noAccount: return Color(DesignSystemConstants.Colors.pendingAmber)
            case .restricted: return Color(DesignSystemConstants.Colors.dangerRed)
            case .temporarilyUnavailable: return Color(DesignSystemConstants.Colors.pendingAmber)
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

        // MARK: — Account Status Refresh

        private func refreshAccountStatus() async {
            // Account status rides the lifecycle layer, which publishes the
            // CK-free mirror the section above renders.
            guard let lifecycleCoordinator else { return }
            let refreshed = await lifecycleCoordinator.refreshCloudAccountStatus()
            if !refreshed {
                toastManager?.show(message: "Could not check your iCloud account status. Please try again.", type: .error)
            }
        }
    }
#else
    struct iCloudStatusView: View {
        init(familyRecordName _: String? = nil) {}

        var body: some View {
            List {
                Section {
                    Text("iCloud Status is only available in Debug builds.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("iCloud Status")
            .navigationBarTitleDisplayMode(.large)
        }
    }
#endif
