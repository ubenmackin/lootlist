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
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "CacheService")
            logger.error("Failed to fetch \(String(describing: T.self)): \(error, privacy: .public)")
            return []
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

    func fetchQuestCompletions(family: String?) -> [QuestCompletionCache] {
        familyScopedFetch(QuestCompletionCache.self, family: family)
    }

    func fetchProfile(recordName: String) -> ProfileCache? {
        fetch(ProfileCache.self, predicate: #Predicate { $0.recordName == recordName }).first
    }

    func fetchProfiles(family: String?) -> [ProfileCache] {
        familyScopedFetch(ProfileCache.self, family: family)
    }

    func fetchQuestTemplates(family: String?) -> [QuestTemplateCache] {
        familyScopedFetch(QuestTemplateCache.self, family: family)
    }

    func fetchFamily(recordName: String) -> FamilyCache? {
        fetch(FamilyCache.self, predicate: #Predicate { $0.recordName == recordName }).first
    }

    func fetchLedgerEntries(profileRecordName: String, family: String? = nil) -> [LedgerEntryCache] {
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

    func fetchProfileAchievements(profileRecordName: String) -> [ProfileAchievementCache] {
        fetch(ProfileAchievementCache.self, predicate: #Predicate { $0.profileRecordName == profileRecordName }, sortBy: [SortDescriptor(\.earnedDate, order: .reverse)])
    }

    func fetchNotificationPreferences(profileRecordName: String) -> [NotificationPreferenceCache] {
        fetch(NotificationPreferenceCache.self, predicate: #Predicate { $0.profileRecordName == profileRecordName })
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
}
