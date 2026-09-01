//
//  QuestService+QuestLogs.swift
//  LootList
//
//  Created by Ben Mackin on August 6, 2026.
//

import CloudKit
import Foundation

// MARK: - Quest Logs & Derived Reads

extension QuestService {
    func fetchStreak(for profile: Profile) async throws -> Int {
        let logs = try await fetchQuestLogs(for: profile)
        guard !logs.isEmpty else { return 0 }

        var daySet: Set<Int> = []
        for log in logs where
            log.verificationStatus == .autoApproved || log.verificationStatus == .verified
        {
            daySet.insert(WeekMath.dayBucket(for: log.completedDate))
        }

        let today = WeekMath.dayBucket(for: Date())
        let yesterday = today - 1
        let anchor = daySet.contains(today) ? today
            : (daySet.contains(yesterday) ? yesterday : nil)
        guard let anchor else { return 0 }

        var streak = 0
        var cursor = anchor

        while daySet.contains(cursor) {
            streak += 1
            cursor -= 1 // Buckets are epoch-day integers, so -1 is exactly one day.
        }
        return streak
    }

    /// Calculates net weekly earnings from quest completions using pure cache math.
    func earnedThisWeek(profile: Profile, weekOf: Date) async throws -> Double {
        let payoutDay = effectivePayoutDay(for: profile)
        let normalizedWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: payoutDay)
        let logs = try await fetchQuestLogs(for: profile)
            .filter { $0.weekOf == normalizedWeek
                && ($0.verificationStatus == .autoApproved
                    || $0.verificationStatus == .verified)
            }

        guard !logs.isEmpty else { return 0 }
        let quests = try await fetchQuestsForLogs(logs, family: appState.family)
        return GoldCalculation.totalCredit(for: quests, logs: logs)
    }

    // WHY: Bespoke multi-step missing-fetch with dictionary merge across cached + CloudKit quests — intentionally inline, not a single-type CacheFirst flow.
    private func fetchQuestsForLogs(
        _ logs: [QuestCompletion],
        family: Family?
    ) async throws -> [Quest] {
        guard !logs.isEmpty else { return [] }
        let needed = Set(logs.map(\.quest.recordID.recordName))
        if let family {
            let cache = cacheService
            let familyName = family.id.recordName
            let scope: CKDatabase.Scope = appState.activeDatabaseScope
            let isAuthoritative = cache.isCacheAuthoritative(familyRecordName: familyName, type: .quest, scope: scope)
            if isAuthoritative {
                let zoneID = family.id.zoneID
                let cached = cache.fetchQuests(family: familyName).map { $0.toQuest(zoneID: zoneID) }
                var map = Dictionary(uniqueKeysWithValues: cached.map { ($0.id.recordName, $0) })
                let missing = needed.filter { map[$0] == nil }
                if missing.isEmpty {
                    return cached.filter { needed.contains($0.id.recordName) }
                }
                let fetched = try await fetchMissingQuestsForLogs(
                    missingNames: Array(missing),
                    family: family
                )
                for quest in fetched {
                    map[quest.id.recordName] = quest
                }
                return Array(map.values).filter { needed.contains($0.id.recordName) }
            }
        }
        if let family {
            return try await fetchMissingQuestsForLogs(
                missingNames: Array(needed),
                family: family
            )
        }
        return []
    }

    private func fetchMissingQuestsForLogs(
        missingNames: [String],
        family: Family
    ) async throws -> [Quest] {
        try await BatchQuestFetcher.fetchMissingQuests(
            names: missingNames,
            family: family,
            cloudKit: cloudKit
        )
    }

    /// Cache-first read. Background refresh handled by CKSyncEngine via push notifications.
    func fetchQuestLogs(forQuest quest: Quest, useCache: Bool = true) async throws -> [QuestCompletion] {
        if !useCache {
            let questRef = CKRecord.Reference(recordID: quest.id, action: .none)
            let predicate = NSPredicate(format: "quest == %@", questRef)
            let all = try await cloudKit.query(
                QuestCompletion.self,
                predicate: predicate,
                in: quest.id.zoneID,
                sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
            )
            await syncCoordinator.delegateHandler.hydrateFromQuery(
                models: all,
                databaseScope: appState.activeDatabaseScope,
                zoneID: quest.id.zoneID
            )
            return all
        }
        let family = Family(
            name: "",
            createdBy: quest.family.recordID,
            id: CKRecord.ID(recordName: quest.family.recordID.recordName, zoneID: quest.id.zoneID)
        )
        return try await CacheFirst.cacheFirst(
            type: .questCompletion,
            family: family,
            cacheService: cacheService,
            appState: appState,
            fetchCache: { [cacheService, quest] familyName in
                cacheService.fetchQuestCompletions(family: familyName)
                    .filter { $0.questRecordName == quest.id.recordName }
            },
            map: { [quest] cache in
                cache.toQuestCompletion(zoneID: quest.id.zoneID)
            },
            query: { [cloudKit, quest] in
                let questRef = CKRecord.Reference(recordID: quest.id, action: .none)
                let predicate = NSPredicate(format: "quest == %@", questRef)
                return try await cloudKit.query(
                    QuestCompletion.self,
                    predicate: predicate,
                    in: quest.id.zoneID,
                    sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
                )
            },
            hydrate: { [syncCoordinator, appState, quest] models in
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: models,
                    databaseScope: appState.activeDatabaseScope,
                    zoneID: quest.id.zoneID
                )
            },
            sortedBy: { $0.completedDate > $1.completedDate }
        )
    }

    /// Cache-first read. Background refresh handled by CKSyncEngine via push notifications.
    func fetchQuestLogs(for profile: Profile) async throws -> [QuestCompletion] {
        let family = Family(
            name: "",
            createdBy: profile.family.recordID,
            id: CKRecord.ID(recordName: profile.family.recordID.recordName, zoneID: profile.id.zoneID)
        )
        return try await CacheFirst.cacheFirst(
            type: .questCompletion,
            family: family,
            cacheService: cacheService,
            appState: appState,
            fetchCache: { [cacheService, profile] familyName in
                cacheService.fetchQuestCompletions(family: familyName)
                    .filter { $0.completerRecordName == profile.id.recordName }
            },
            map: { [profile] cache in
                cache.toQuestCompletion(zoneID: profile.id.zoneID)
            },
            query: { [cloudKit, profile] in
                let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                let pred = NSPredicate(format: "completedBy == %@", profileRef)
                return try await cloudKit.query(
                    QuestCompletion.self,
                    predicate: pred,
                    in: profile.id.zoneID,
                    sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
                )
            },
            hydrate: { [syncCoordinator, appState, profile] models in
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: models,
                    databaseScope: appState.activeDatabaseScope,
                    zoneID: profile.id.zoneID
                )
            },
            sortedBy: { $0.completedDate > $1.completedDate }
        )
    }

    // MARK: - Batch Fetch

    /// Cache-first read. Background refresh handled by CKSyncEngine via push notifications.
    func fetchQuestCompletionsForFamily(family: Family) async throws -> [QuestCompletion] {
        try await CacheFirst.cacheFirst(
            type: .questCompletion,
            family: family,
            cacheService: cacheService,
            appState: appState,
            fetchCache: { [cacheService] familyName in
                cacheService.fetchQuestCompletions(family: familyName)
            },
            map: { [family] cache in
                cache.toQuestCompletion(zoneID: family.id.zoneID)
            },
            query: { [cloudKit, family] in
                let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
                let predicate = NSPredicate(format: "family == %@", familyRef)
                return try await cloudKit.query(
                    QuestCompletion.self,
                    predicate: predicate,
                    in: family.id.zoneID,
                    sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
                )
            },
            hydrate: { [syncCoordinator, appState, family] models in
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: models,
                    databaseScope: appState.activeDatabaseScope,
                    zoneID: family.id.zoneID
                )
            }
        )
    }
}
