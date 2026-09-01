//
//  CacheService+Fetches.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import os
import SwiftData

@MainActor
extension CacheService {
    private static let fetchLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "CacheService")

    // MARK: - Generic helper

    /// Generic fetch helper that handles the common fetch pattern.
    func fetch<T: PersistentModel>(
        _: T.Type,
        predicate: Predicate<T>? = nil,
        sortBy: [SortDescriptor<T>] = []
    ) -> [T] {
        guard let context else { return [] }
        do {
            let descriptor = FetchDescriptor<T>(predicate: predicate, sortBy: sortBy)
            return try context.fetch(descriptor)
        } catch {
            Self.fetchLogger.error("Failed to fetch \(String(describing: T.self), privacy: .private): \(error, privacy: .private)")
            return []
        }
    }

    /// Fail-closed variant of `fetch`: returns `nil` when the cache context is unavailable or the
    /// underlying fetch throws, instead of collapsing the failure into an empty array.
    func tryFetch<T: PersistentModel>(
        _: T.Type,
        predicate: Predicate<T>? = nil,
        sortBy: [SortDescriptor<T>] = []
    ) -> [T]? {
        guard let context else { return nil }
        do {
            let descriptor = FetchDescriptor<T>(predicate: predicate, sortBy: sortBy)
            return try context.fetch(descriptor)
        } catch {
            Self.fetchLogger.error("Failed to fetch \(String(describing: T.self), privacy: .private): \(error, privacy: .private)")
            return nil
        }
    }

    /// Fetches every record of `T`, optionally scoped to a single family and sorted by `sortBy`.
    func familyScopedFetch<T: FamilyScopedCache>(
        _ type: T.Type,
        family: String?,
        sortBy: [SortDescriptor<T>] = []
    ) -> [T] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("familyScopedFetch<\(String(describing: T.self), privacy: .private)> called without family scope — returning empty (fail-closed)")
            return []
        }
        let predicate: Predicate<T> = #Predicate<T> { $0.familyRecordName == family }
        return fetch(type, predicate: predicate, sortBy: sortBy)
    }

    /// Generic FamilyScoped fetch helper — single predicate source for every
    /// family-scoped cache read. Reduces per-type boilerplate; future cached
    /// types get fetch for free by conforming to ``FamilyScopedFetchable``.
    func fetchAll<T: FamilyScopedFetchable>(_ type: T.Type, family: String) -> [T] {
        guard !family.isEmpty else {
            Self.fetchLogger.warning("fetchAll<\(String(describing: T.self), privacy: .private)> called without family scope — returning empty (fail-closed)")
            return []
        }
        return fetch(type, predicate: #Predicate { $0.familyRecordName == family })
    }

    /// Sorted overload for call sites that require deterministic ordering.
    func fetchAll<T: FamilyScopedFetchable>(_ type: T.Type, family: String, sortBy: [SortDescriptor<T>]) -> [T] {
        guard !family.isEmpty else {
            Self.fetchLogger.warning("fetchAll<\(String(describing: T.self), privacy: .private)> called without family scope — returning empty (fail-closed)")
            return []
        }
        let predicate: Predicate<T> = #Predicate<T> { $0.familyRecordName == family }
        return fetch(type, predicate: predicate, sortBy: sortBy)
    }

    // MARK: - Public fetch API

    /// Fetches quests, optionally filtered by family and/or a week range.
    func fetchQuests(family: String?, weekInRange: Range<Date>?) -> [QuestCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchQuests called without family scope — returning empty (fail-closed)")
            return []
        }
        if let range = weekInRange {
            let start = range.lowerBound
            let end = range.upperBound
            return fetch(
                QuestCache.self,
                predicate: #Predicate { item in
                    item.familyRecordName == family
                        && item.weekOf >= start
                        && item.weekOf < end
                }
            )
        }
        return fetchAll(QuestCache.self, family: family)
    }

    /// Protocol witness for `CacheServicing.fetchQuests(family:)` – forwards to the ranged fetch with nil range.
    func fetchQuests(family: String?) -> [QuestCache] {
        fetchQuests(family: family, weekInRange: nil)
    }

    func fetchQuest(recordName: String, family: String) -> QuestCache? {
        fetch(QuestCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchQuest(identity: ScopedRecordIdentity) -> QuestCache? {
        guard let family = identity.familyRecordName else { return nil }
        return fetchQuest(recordName: identity.recordID.recordName, family: family)
    }

    func fetchQuestCompletions(family: String?) -> [QuestCompletionCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchQuestCompletions called without family scope — returning empty (fail-closed)")
            return []
        }
        return fetchAll(QuestCompletionCache.self, family: family)
    }

    func fetchQuestCompletion(recordName: String, family: String) -> QuestCompletionCache? {
        fetch(QuestCompletionCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchQuestCompletion(identity: ScopedRecordIdentity) -> QuestCompletionCache? {
        guard let family = identity.familyRecordName else { return nil }
        return fetchQuestCompletion(recordName: identity.recordID.recordName, family: family)
    }

    func fetchProfile(recordName: String, family: String) -> ProfileCache? {
        fetch(ProfileCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchProfile(identity: ScopedRecordIdentity) -> ProfileCache? {
        guard let family = identity.familyRecordName else { return nil }
        return fetchProfile(recordName: identity.recordID.recordName, family: family)
    }

    func fetchProfiles(family: String?) -> [ProfileCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchProfiles called without family scope — returning empty (fail-closed)")
            return []
        }
        return fetchAll(ProfileCache.self, family: family)
    }

    func fetchQuestTemplates(family: String?) -> [QuestTemplateCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchQuestTemplates called without family scope — returning empty (fail-closed)")
            return []
        }
        return fetchAll(QuestTemplateCache.self, family: family)
    }

    func fetchQuestTemplate(recordName: String, family: String) -> QuestTemplateCache? {
        fetch(QuestTemplateCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchQuestTemplate(identity: ScopedRecordIdentity) -> QuestTemplateCache? {
        guard let family = identity.familyRecordName else { return nil }
        return fetchQuestTemplate(recordName: identity.recordID.recordName, family: family)
    }

    func fetchFamily(recordName: String) -> FamilyCache? {
        fetch(FamilyCache.self, predicate: #Predicate { $0.recordName == recordName }).first
    }

    func fetchFamily(identity: ScopedRecordIdentity) -> FamilyCache? {
        fetchFamily(recordName: identity.recordID.recordName)
    }

    func fetchLedgerEntry(recordName: String, family: String) -> LedgerEntryCache? {
        fetch(LedgerEntryCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchLedgerEntry(identity: ScopedRecordIdentity) -> LedgerEntryCache? {
        guard let family = identity.familyRecordName else { return nil }
        return fetchLedgerEntry(recordName: identity.recordID.recordName, family: family)
    }

    func fetchAllowancePeriod(recordName: String, family: String) -> AllowancePeriodCache? {
        fetch(AllowancePeriodCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchAllowancePeriod(identity: ScopedRecordIdentity) -> AllowancePeriodCache? {
        guard let family = identity.familyRecordName else { return nil }
        return fetchAllowancePeriod(recordName: identity.recordID.recordName, family: family)
    }

    func fetchAchievement(recordName: String, family: String) -> AchievementCache? {
        fetch(AchievementCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchAchievement(identity: ScopedRecordIdentity) -> AchievementCache? {
        guard let family = identity.familyRecordName else { return nil }
        return fetchAchievement(recordName: identity.recordID.recordName, family: family)
    }

    func fetchProfileAchievement(recordName: String, family: String) -> ProfileAchievementCache? {
        fetch(ProfileAchievementCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchProfileAchievement(identity: ScopedRecordIdentity) -> ProfileAchievementCache? {
        guard let family = identity.familyRecordName else { return nil }
        return fetchProfileAchievement(recordName: identity.recordID.recordName, family: family)
    }

    func fetchNotificationPreference(recordName: String, family: String) -> NotificationPreferenceCache? {
        fetch(NotificationPreferenceCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchNotificationPreference(identity: ScopedRecordIdentity) -> NotificationPreferenceCache? {
        guard let family = identity.familyRecordName else { return nil }
        return fetchNotificationPreference(recordName: identity.recordID.recordName, family: family)
    }

    func fetchLedgerEntries(profileRecordName: String, family: String? = nil) -> [LedgerEntryCache] {
        #if DEBUG
            ledgerEntryFetchScopes.append(family)
        #endif
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchLedgerEntries(profileRecordName:) called without family scope — returning empty (fail-closed)")
            return []
        }
        return fetch(
            LedgerEntryCache.self,
            predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == family },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
    }

    /// WHY DB-level predicate: the per-day transfer guard previously pulled all
    /// ledger rows for a profile and scanned on the main thread. This fetch
    /// narrows to the (family, profile, source, date) subset via composite
    /// index (familyRecordName, profileRecordName, source, date); pair filter
    /// (fromBucket/toBucket) refines the small subset in-memory, avoiding O(n)
    /// main-thread scans.
    func fetchTransfers(
        profileRecordName: String,
        familyRecordName: String,
        from fromRaw: String,
        to toRaw: String,
        dayBucket: Int
    ) -> [LedgerEntryCache] {
        guard !familyRecordName.isEmpty, !profileRecordName.isEmpty else {
            Self.fetchLogger.warning("fetchTransfers called without family/profile scope — returning empty (fail-closed)")
            return []
        }
        guard !fromRaw.isEmpty, !toRaw.isEmpty else { return [] }
        let range = WeekMath.utcDateRange(forDayBucket: dayBucket)
        let todayStart = range.lowerBound
        let todayEnd = range.upperBound
        let transferSource = LedgerSource.transfer.rawValue
        return fetch(
            LedgerEntryCache.self,
            predicate: #Predicate { entry in
                entry.profileRecordName == profileRecordName
                    && entry.familyRecordName == familyRecordName
                    && entry.source == transferSource
                    && entry.fromBucket == fromRaw
                    && entry.toBucket == toRaw
                    && entry.date >= todayStart
                    && entry.date < todayEnd
            }
        )
    }

    func fetchLedgerEntries(profileRecordName: String, family: String, recordNamePrefix: String) -> [LedgerEntryCache] {
        guard !family.isEmpty else {
            Self.fetchLogger.warning("fetchLedgerEntries(profileRecordName:family:recordNamePrefix:) called without family scope — returning empty (fail-closed)")
            return []
        }
        let prefix = recordNamePrefix
        return fetch(
            LedgerEntryCache.self,
            predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == family && $0.recordName.starts(with: prefix) }
        )
    }

    func fetchLedgerEntries(family: String?) -> [LedgerEntryCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchLedgerEntries(family:) called without family scope — returning empty (fail-closed)")
            return []
        }
        return fetchAll(
            LedgerEntryCache.self,
            family: family,
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
    }

    func fetchAllowancePeriods(profileRecordName: String, family: String? = nil) -> [AllowancePeriodCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchAllowancePeriods(profileRecordName:) called without family scope — returning empty (fail-closed)")
            return []
        }
        return fetch(
            AllowancePeriodCache.self,
            predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == family },
            sortBy: [SortDescriptor(\.weekOf, order: .reverse)]
        )
    }

    func fetchAllowancePeriods(family: String?) -> [AllowancePeriodCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchAllowancePeriods(family:) called without family scope — returning empty (fail-closed)")
            return []
        }
        return fetchAll(
            AllowancePeriodCache.self,
            family: family,
            sortBy: [SortDescriptor(\.weekOf, order: .reverse)]
        )
    }

    func fetchAchievements(family: String?) -> [AchievementCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchAchievements called without family scope — returning empty (fail-closed)")
            return []
        }
        return fetchAll(AchievementCache.self, family: family)
    }

    func fetchProfileAchievements(profileRecordName: String, family: String? = nil) -> [ProfileAchievementCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchProfileAchievements(profileRecordName:) called without family scope — returning empty (fail-closed)")
            return []
        }
        return fetch(
            ProfileAchievementCache.self,
            predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == family },
            sortBy: [SortDescriptor(\.earnedDate, order: .reverse)]
        )
    }

    func fetchNotificationPreferences(profileRecordName: String, family: String? = nil) -> [NotificationPreferenceCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchNotificationPreferences(profileRecordName:) called without family scope — returning empty (fail-closed)")
            return []
        }
        return fetch(
            NotificationPreferenceCache.self,
            predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == family }
        )
    }

    func fetchNotificationPreference(profileRecordName: String, familyRecordName: String, eventType: String) -> NotificationPreferenceCache? {
        fetch(
            NotificationPreferenceCache.self,
            predicate: #Predicate {
                $0.profileRecordName == profileRecordName
                    && $0.familyRecordName == familyRecordName
                    && $0.eventType == eventType
            }
        ).first
    }

    func fetchGemLedgers(family: String?) -> [GemLedgerCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchGemLedgers called without family scope — returning empty (fail-closed)")
            return []
        }
        return fetchAll(GemLedgerCache.self, family: family)
    }

    func fetchGemLedgers(profileRecordName: String, family: String) -> [GemLedgerCache] {
        guard !family.isEmpty else { return [] }
        return fetch(
            GemLedgerCache.self,
            predicate: #Predicate {
                $0.profileRecordName == profileRecordName && $0.familyRecordName == family
            }
        )
    }

    func fetchGemLedger(recordName: String, family: String) -> GemLedgerCache? {
        fetch(GemLedgerCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchRewardEvents(family: String?) -> [RewardEventCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchRewardEvents called without family scope — returning empty (fail-closed)")
            return []
        }
        return fetchAll(RewardEventCache.self, family: family)
    }

    func fetchRewardEvent(recordName: String, family: String) -> RewardEventCache? {
        fetch(RewardEventCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchRewardEvent(identity: ScopedRecordIdentity) -> RewardEventCache? {
        guard let family = identity.familyRecordName else { return nil }
        return fetchRewardEvent(recordName: identity.recordID.recordName, family: family)
    }

    func fetchGoals(family: String?) -> [GoalCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchGoals called without family scope — returning empty (fail-closed)")
            return []
        }
        return fetchAll(GoalCache.self, family: family)
    }

    /// FIFO fill order for a single bucket: oldest incomplete non-archived
    /// goal first, matching the bucket cascade rules.
    func fetchGoals(profileRecordName: String, bucketKind: String, familyRecordName: String) -> [GoalCache] {
        fetch(
            GoalCache.self,
            predicate: #Predicate {
                $0.familyRecordName == familyRecordName
                    && $0.profileRecordName == profileRecordName
                    && $0.bucketKind == bucketKind
            },
            sortBy: [SortDescriptor(\GoalCache.createdAt)]
        )
    }

    func fetchGoal(recordName: String, family: String) -> GoalCache? {
        fetch(GoalCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchGoal(identity: ScopedRecordIdentity) -> GoalCache? {
        guard let family = identity.familyRecordName else { return nil }
        return fetchGoal(recordName: identity.recordID.recordName, family: family)
    }
}
