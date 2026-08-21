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

    /// Fail-closed variant of `fetch`: returns `nil` when the cache context is
    /// unavailable or the underlying fetch throws, instead of collapsing the
    /// failure into an empty array. Callers that must *prove* absence (e.g.
    /// local-deletion confirmation before enqueueing a server-side delete)
    /// use this so a cache failure is never mistaken for "no rows exist".
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

    /// Fetches every record of `T`, optionally scoped to a single family and sorted
    /// by `sortBy`. Returns `[]` if the fetch fails (mirrors the inline
    /// `(try? context.fetch(...)) ?? []` pattern used elsewhere in this service).
    /// Constrained to `FamilyScopedCache` so the family predicate compiles
    /// without per-type duplication.
    func familyScopedFetch<T: FamilyScopedCache>(
        _ type: T.Type,
        family: String?,
        sortBy: [SortDescriptor<T>] = []
    ) -> [T] {
        let predicate: Predicate<T>?
        if let family {
            predicate = #Predicate<T> { $0.familyRecordName == family }
        } else {
            predicate = nil
        }
        return fetch(type, predicate: predicate, sortBy: sortBy)
    }

    // MARK: - Public fetch API

    /// Fetches quests, optionally filtered by family and/or a week range.
    func fetchQuests(family: String?, weekInRange: Range<Date>? = nil) -> [QuestCache] {
        let predicate: Predicate<QuestCache>?
        if let range = weekInRange {
            let start = range.lowerBound
            let end = range.upperBound
            if let family {
                predicate = #Predicate { item in
                    item.familyRecordName == family
                        && item.weekOf >= start
                        && item.weekOf < end
                }
            } else {
                predicate = #Predicate { item in
                    item.weekOf >= start
                        && item.weekOf < end
                }
            }
        } else if let family {
            predicate = #Predicate { item in
                item.familyRecordName == family
            }
        } else {
            predicate = nil
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

    func fetchQuestCompletions(family: String?) -> [QuestCompletionCache] {
        familyScopedFetch(QuestCompletionCache.self, family: family)
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
        familyScopedFetch(ProfileCache.self, family: family)
    }

    func fetchQuestTemplates(family: String?) -> [QuestTemplateCache] {
        familyScopedFetch(QuestTemplateCache.self, family: family)
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
        if let family {
            return fetch(
                LedgerEntryCache.self,
                predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == family },
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
        }
        return fetch(
            LedgerEntryCache.self,
            predicate: #Predicate { $0.profileRecordName == profileRecordName },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
    }

    func fetchLedgerEntries(family: String?) -> [LedgerEntryCache] {
        familyScopedFetch(
            LedgerEntryCache.self,
            family: family,
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
    }

    func fetchAllowancePeriods(profileRecordName: String, family: String? = nil) -> [AllowancePeriodCache] {
        if let family {
            return fetch(
                AllowancePeriodCache.self,
                predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == family },
                sortBy: [SortDescriptor(\.weekOf, order: .reverse)]
            )
        }
        return fetch(
            AllowancePeriodCache.self,
            predicate: #Predicate { $0.profileRecordName == profileRecordName },
            sortBy: [SortDescriptor(\.weekOf, order: .reverse)]
        )
    }

    func fetchAllowancePeriods(family: String?) -> [AllowancePeriodCache] {
        familyScopedFetch(
            AllowancePeriodCache.self,
            family: family,
            sortBy: [SortDescriptor(\.weekOf, order: .reverse)]
        )
    }

    func fetchAchievements(family: String?) -> [AchievementCache] {
        familyScopedFetch(AchievementCache.self, family: family)
    }

    func fetchProfileAchievements(profileRecordName: String, family: String? = nil) -> [ProfileAchievementCache] {
        if let family {
            return fetch(
                ProfileAchievementCache.self,
                predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == family },
                sortBy: [SortDescriptor(\.earnedDate, order: .reverse)]
            )
        }
        return fetch(
            ProfileAchievementCache.self,
            predicate: #Predicate { $0.profileRecordName == profileRecordName },
            sortBy: [SortDescriptor(\.earnedDate, order: .reverse)]
        )
    }

    func fetchNotificationPreferences(profileRecordName: String, family: String? = nil) -> [NotificationPreferenceCache] {
        if let family {
            return fetch(
                NotificationPreferenceCache.self,
                predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == family }
            )
        }
        return fetch(
            NotificationPreferenceCache.self,
            predicate: #Predicate { $0.profileRecordName == profileRecordName }
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
        familyScopedFetch(GemLedgerCache.self, family: family)
    }

    func fetchGemLedger(recordName: String, family: String) -> GemLedgerCache? {
        fetch(GemLedgerCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchRewardEvents(family: String?) -> [RewardEventCache] {
        familyScopedFetch(RewardEventCache.self, family: family)
    }

    func fetchRewardEvent(recordName: String, family: String) -> RewardEventCache? {
        fetch(RewardEventCache.self, predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == family }).first
    }

    func fetchRewardEvent(identity: ScopedRecordIdentity) -> RewardEventCache? {
        guard let family = identity.familyRecordName else { return nil }
        return fetchRewardEvent(recordName: identity.recordID.recordName, family: family)
    }
}
