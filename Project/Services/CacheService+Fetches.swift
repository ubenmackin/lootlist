//
//  CacheService+Fetches.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import SwiftData

extension CacheService {
    // MARK: - Generic helper

    /// Fetches every record of `T`, optionally scoped to a single family and sorted
    /// by `sortBy`. Returns `[]` if the fetch fails (mirrors the inline
    /// `(try? context.fetch(...)) ?? []` pattern used elsewhere in this service).
    /// Constrained to `FamilyScopedCache` so the family predicate compiles
    /// without per-type duplication.
    func familyScopedFetch<T: FamilyScopedCache>(
        _: T.Type,
        family: String?,
        sortBy: [SortDescriptor<T>] = []
    ) -> [T] {
        let descriptor: FetchDescriptor<T> = if let family {
            FetchDescriptor(predicate: #Predicate { $0.familyRecordName == family }, sortBy: sortBy)
        } else {
            FetchDescriptor(sortBy: sortBy)
        }
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Public fetch API

    /// Fetches quests, optionally filtered by family and/or a week range.
    func fetchQuests(family: String?, weekInRange: Range<Date>? = nil) -> [QuestCache] {
        var descriptor: FetchDescriptor<QuestCache>
        if let range = weekInRange {
            let start = range.lowerBound
            let end = range.upperBound
            if let family {
                descriptor = FetchDescriptor(predicate: #Predicate { item in
                    item.familyRecordName == family
                        && item.weekOf >= start
                        && item.weekOf < end
                })
            } else {
                descriptor = FetchDescriptor(predicate: #Predicate { item in
                    item.weekOf >= start
                        && item.weekOf < end
                })
            }
        } else if let family {
            descriptor = FetchDescriptor(predicate: #Predicate { item in
                item.familyRecordName == family
            })
        } else {
            descriptor = FetchDescriptor()
        }
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchQuestCompletions(family: String?) -> [QuestCompletionCache] {
        familyScopedFetch(QuestCompletionCache.self, family: family)
    }

    func fetchProfile(recordName: String) -> ProfileCache? {
        let descriptor = FetchDescriptor<ProfileCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        return try? context.fetch(descriptor).first
    }

    func fetchProfiles(family: String?) -> [ProfileCache] {
        familyScopedFetch(ProfileCache.self, family: family)
    }

    func fetchQuestTemplates(family: String?) -> [QuestTemplateCache] {
        familyScopedFetch(QuestTemplateCache.self, family: family)
    }

    func fetchFamily(recordName: String) -> FamilyCache? {
        let descriptor = FetchDescriptor<FamilyCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        return try? context.fetch(descriptor).first
    }

    func fetchLedgerEntries(profileRecordName: String) -> [LedgerEntryCache] {
        let descriptor = FetchDescriptor<LedgerEntryCache>(
            predicate: #Predicate { $0.profileRecordName == profileRecordName },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchLedgerEntries(family: String?) -> [LedgerEntryCache] {
        familyScopedFetch(
            LedgerEntryCache.self,
            family: family,
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
    }

    func fetchAllowancePeriods(profileRecordName: String) -> [AllowancePeriodCache] {
        let descriptor = FetchDescriptor<AllowancePeriodCache>(
            predicate: #Predicate { $0.profileRecordName == profileRecordName },
            sortBy: [SortDescriptor(\.weekOf, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
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

    func fetchProfileAchievements(profileRecordName: String) -> [ProfileAchievementCache] {
        let descriptor = FetchDescriptor<ProfileAchievementCache>(
            predicate: #Predicate { $0.profileRecordName == profileRecordName },
            sortBy: [SortDescriptor(\.earnedDate, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchNotificationPreferences(profileRecordName: String) -> [NotificationPreferenceCache] {
        let descriptor = FetchDescriptor<NotificationPreferenceCache>(
            predicate: #Predicate { $0.profileRecordName == profileRecordName }
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
