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
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "iCloudStatusView")
    @Environment(AppState.self) private var appState
    @Environment(CKSyncEngineCoordinator.self) private var syncCoordinator: CKSyncEngineCoordinator?
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?
    @Environment(AppSyncCoordinator.self) private var appSyncCoordinator: AppSyncCoordinator?
    @Environment(NetworkMonitor.self) private var networkMonitor: NetworkMonitor?
    @Environment(ToastManager.self) private var toastManager: ToastManager?

    private let familyRecordName: String?

    // DEBUG-only diagnostic overlay inspects all cached records.
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

    private var accountStatus: CloudAccountStatus {
        appState.cloudAccountStatus
    }

    init(familyRecordName: String? = nil) {
        self.familyRecordName = familyRecordName

        // Scope every query to the active family at the SwiftData store layer.
        // When familyRecordName is nil, scope to "" so zero rows return rather than
        // leaking cross-family rows into a multifamily device.
        let targetFamily = familyRecordName ?? ""
        FamilyScopeValidator.assertNonEmpty(targetFamily: targetFamily, viewName: "iCloudStatusView")
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

    // MARK: - Debug Helpers

    private var debugFamilyRecordName: String? {
        familyRecordName ?? appState.activeFamilyRecordName
    }

    private func relativeText(for date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }

    private func absoluteText(for date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func freshnessChip(isFresh: Bool) -> some View {
        Text(isFresh ? "✅" : "❌")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(
                        isFresh
                            ? Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.18)
                            : Color(DesignSystemConstants.Colors.dangerRed).opacity(0.12)
                    )
            )
            .overlay(
                Capsule()
                    .stroke(
                        isFresh
                            ? Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.35)
                            : Color(DesignSystemConstants.Colors.dangerRed).opacity(0.25),
                        lineWidth: 0.5
                    )
            )
    }

    // MARK: Body

    var body: some View {
        List {
            syncStatusSection
            networkSection
            recordCountsSection
            cloudKitAccountSection
            #if DEBUG
                debugSyncHealthSection
            #endif
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

    // MARK: Section 5 — Debug — Sync Health (DEBUG overlay, read-only)

    #if DEBUG
        /// Diagnostic view inspecting OS APNs token and CloudKit subscription states.
        private var debugSyncHealthSection: some View {
            Section {
                // lastSyncedAt — relative + absolute
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Last Synced")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(relativeText(for: syncCoordinator?.lastSyncedAt))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(syncCoordinator?.lastSyncedAt == nil ? Color(DesignSystemConstants.Colors.pendingAmber) : Color.primary)
                    }
                    HStack {
                        Text(absoluteText(for: syncCoordinator?.lastSyncedAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(.vertical, 2)

                // syncError
                if let error = syncCoordinator?.syncError, !error.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sync Error")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }

                // Push age — time since last fetchedRecordZoneChanges / reconciliation
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Last Push / Reconcile")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(relativeText(for: syncCoordinator?.lastPushReceivedAt))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(syncCoordinator?.lastPushReceivedAt == nil ? Color(DesignSystemConstants.Colors.pendingAmber) : Color.primary)
                    }
                    HStack {
                        Text(absoluteText(for: syncCoordinator?.lastPushReceivedAt))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let pushDate = syncCoordinator?.lastPushReceivedAt {
                            Text(pushAgeText(for: pushDate))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)

                // Engine state
                VStack(alignment: .leading, spacing: 6) {
                    Text("Engine State")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Label(
                            syncCoordinator?.activeEngine(isOwner: true) != nil ? "private: active" : "private: nil",
                            systemImage: syncCoordinator?.activeEngine(isOwner: true) != nil ? "checkmark.circle.fill" : "xmark.circle"
                        )
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(syncCoordinator?.activeEngine(isOwner: true) != nil ? Color(DesignSystemConstants.Colors.primaryGreen) : Color.secondary)

                        Label(
                            syncCoordinator?.activeEngine(isOwner: false) != nil ? "shared: active" : "shared: nil",
                            systemImage: syncCoordinator?.activeEngine(isOwner: false) != nil ? "checkmark.circle.fill" : "xmark.circle"
                        )
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(syncCoordinator?.activeEngine(isOwner: false) != nil ? Color(DesignSystemConstants.Colors.primaryGreen) : Color.secondary)
                    }
                    HStack {
                        Text("Pending Uploads")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(syncCoordinator?.pendingUploadCount ?? 0)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle((syncCoordinator?.pendingUploadCount ?? 0) > 0 ? Color(DesignSystemConstants.Colors.pendingAmber) : Color.secondary)
                    }
                }
                .padding(.vertical, 2)

                // Reconnect debounce
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reconnect Debounce")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Interval")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(lifecycleCoordinator?.reconnectDebounceIntervalForDebug ?? 45))s")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    }
                    HStack {
                        Text("Last Reconnect Sync")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(relativeText(for: lifecycleCoordinator?.lastReconnectTriggeredSyncAtForDebug))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    if let lastReconnect = lifecycleCoordinator?.lastReconnectTriggeredSyncAtForDebug {
                        HStack {
                            Text(absoluteText(for: lastReconnect))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
                .padding(.vertical, 2)

                // AppSyncCoordinator last fetch / notification
                if let lastNotification = appSyncCoordinator?.lastNotificationReceivedAt {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Push Notification")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("Last Push Notification")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(relativeText(for: lastNotification))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(absoluteText(for: lastNotification))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    .padding(.vertical, 2)
                } else {
                    HStack {
                        Text("Last Push Notification")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("No push yet")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                    }
                    .padding(.vertical, 2)
                }

                // Per-scope freshness — ✅/❌ chips per CachedRecordType
                VStack(alignment: .leading, spacing: 8) {
                    Text("Per-Scope Freshness")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("private / shared — ✅ fresh  ❌ stale")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(CachedRecordType.allCases, id: \.rawValue) { type in
                        let privateFresh = appState.cacheService?.isCacheFresh(
                            familyRecordName: debugFamilyRecordName ?? "",
                            type: type,
                            scope: .private
                        ) ?? false
                        let sharedFresh = appState.cacheService?.isCacheFresh(
                            familyRecordName: debugFamilyRecordName ?? "",
                            type: type,
                            scope: .shared
                        ) ?? false
                        HStack {
                            Text(type.rawValue)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            HStack(spacing: 6) {
                                HStack(spacing: 2) {
                                    Text("P")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.secondary)
                                    freshnessChip(isFresh: privateFresh)
                                }
                                HStack(spacing: 2) {
                                    Text("S")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.secondary)
                                    freshnessChip(isFresh: sharedFresh)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("Debug — Sync Health")
            } footer: {
                Text("Read-only diagnostics for push regression triage. No manual sync here — use Sync Now above.")
                    .font(.caption2)
            }
        }

        private func pushAgeText(for date: Date) -> String {
            let seconds = Int(Date().timeIntervalSince(date))
            if seconds < 60 {
                return "\(seconds)s ago"
            }
            if seconds < 3600 {
                return "\(seconds / 60)m ago"
            }
            if seconds < 86400 {
                return "\(seconds / 3600)h ago"
            }
            return "\(seconds / 86400)d ago"
        }
    #endif

    // MARK: Section 6 — Actions

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

            #if DEBUG
                if let lastSyncedAt = syncCoordinator?.lastSyncedAt {
                    Text("Last synced \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            #endif
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
