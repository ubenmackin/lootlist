//
//  CacheService+Fetches.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import os
import SwiftData

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

    // MARK: - Public fetch API

    /// Fetches quests, optionally filtered by family and/or a week range.
    /// WHY: unscoped family fetch would return rows across ALL families — fail closed instead of leaking cross-family data.
    func fetchQuests(family: String?, weekInRange: Range<Date>? = nil) -> [QuestCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchQuests called without family scope — returning empty (fail-closed)")
            return []
        }
        let predicate: Predicate<QuestCache>?
        if let range = weekInRange {
            let start = range.lowerBound
            let end = range.upperBound
            predicate = #Predicate { item in
                item.familyRecordName == family
                    && item.weekOf >= start
                    && item.weekOf < end
            }
        } else {
            predicate = #Predicate { item in
                item.familyRecordName == family
            }
        }
        return fetch(QuestCache.self, predicate: predicate)
    }

    func fetchQuest(recordName: String, family: String) -> QuestCache? {
        fetch(QuestCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchQuest(identity: ScopedRecordIdentity) -> QuestCache? {
        guard let family = identity.familyRecordName else { return nil }
        return fetchQuest(recordName: identity.recordID.recordName, family: family)
    }

    // WHY: Pending-review completions (`verificationStatus == "pending"`) are the stall case — this fetch must not filter them out; parent `@Query` badge depends on them.
    func fetchQuestCompletions(family: String?) -> [QuestCompletionCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchQuestCompletions called without family scope — returning empty (fail-closed)")
            return []
        }
        return familyScopedFetch(QuestCompletionCache.self, family: family)
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

    // WHY: unscoped family fetch would return rows across ALL families — fail closed instead of leaking cross-family data.
    func fetchProfiles(family: String?) -> [ProfileCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchProfiles called without family scope — returning empty (fail-closed)")
            return []
        }
        return familyScopedFetch(ProfileCache.self, family: family)
    }

    // WHY: unscoped family fetch would return rows across ALL families — fail closed instead of leaking cross-family data.
    func fetchQuestTemplates(family: String?) -> [QuestTemplateCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchQuestTemplates called without family scope — returning empty (fail-closed)")
            return []
        }
        return familyScopedFetch(QuestTemplateCache.self, family: family)
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

    // WHY: a profile-scoped fetch without a family scope would read rows across
    // ALL families — fail closed instead of leaking cross-family data.
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

    // WHY: unscoped family fetch would return rows across ALL families — fail closed instead of leaking cross-family data.
    func fetchLedgerEntries(family: String?) -> [LedgerEntryCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchLedgerEntries(family:) called without family scope — returning empty (fail-closed)")
            return []
        }
        return familyScopedFetch(
            LedgerEntryCache.self,
            family: family,
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
    }

    // WHY: a profile-scoped fetch without a family scope would read rows across
    // ALL families — fail closed instead of leaking cross-family data.
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

    // WHY: unscoped family fetch would return rows across ALL families — fail closed instead of leaking cross-family data.
    func fetchAllowancePeriods(family: String?) -> [AllowancePeriodCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchAllowancePeriods(family:) called without family scope — returning empty (fail-closed)")
            return []
        }
        return familyScopedFetch(
            AllowancePeriodCache.self,
            family: family,
            sortBy: [SortDescriptor(\.weekOf, order: .reverse)]
        )
    }

    // WHY: unscoped family fetch would return rows across ALL families — fail closed instead of leaking cross-family data.
    func fetchAchievements(family: String?) -> [AchievementCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchAchievements called without family scope — returning empty (fail-closed)")
            return []
        }
        return familyScopedFetch(AchievementCache.self, family: family)
    }

    // WHY: a profile-scoped fetch without a family scope would read rows across
    // ALL families — fail closed instead of leaking cross-family data.
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

    // WHY: a profile-scoped fetch without a family scope would read rows across
    // ALL families — fail closed instead of leaking cross-family data.
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

    // WHY: unscoped family fetch would return rows across ALL families — fail closed instead of leaking cross-family data.
    func fetchGemLedgers(family: String?) -> [GemLedgerCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchGemLedgers called without family scope — returning empty (fail-closed)")
            return []
        }
        return familyScopedFetch(GemLedgerCache.self, family: family)
    }

    func fetchGemLedger(recordName: String, family: String) -> GemLedgerCache? {
        fetch(GemLedgerCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    // WHY: unscoped family fetch would return rows across ALL families — fail closed instead of leaking cross-family data.
    func fetchRewardEvents(family: String?) -> [RewardEventCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchRewardEvents called without family scope — returning empty (fail-closed)")
            return []
        }
        return familyScopedFetch(RewardEventCache.self, family: family)
    }

    func fetchRewardEvent(recordName: String, family: String) -> RewardEventCache? {
        fetch(RewardEventCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchRewardEvent(identity: ScopedRecordIdentity) -> RewardEventCache? {
        guard let family = identity.familyRecordName else { return nil }
        return fetchRewardEvent(recordName: identity.recordID.recordName, family: family)
    }

    // WHY: unscoped family fetch would return rows across ALL families — fail closed instead of leaking cross-family data.
    func fetchGoals(family: String?) -> [GoalCache] {
        guard let family, !family.isEmpty else {
            Self.fetchLogger.warning("fetchGoals called without family scope — returning empty (fail-closed)")
            return []
        }
        return familyScopedFetch(GoalCache.self, family: family)
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
