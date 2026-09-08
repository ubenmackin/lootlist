//
//  QuestCompletionService+QuestLogs.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import CloudKit
import Foundation
import os

// MARK: - Quest Logs & Derived Reads

extension QuestCompletionService {
    /// Strictly-local cached logs for a quest, sorted newest-first.
    func cachedQuestLogs(forQuest quest: Quest) -> [QuestCompletion] {
        let cache = cacheService
        let questName = quest.id.recordName
        return cache.fetchQuestCompletions(family: quest.family.recordID.recordName)
            .filter { $0.questRecordName == questName }
            .map { $0.toQuestCompletion(zoneID: quest.id.zoneID) }
            .sorted { $0.completedDate > $1.completedDate }
    }

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

    func earnedThisWeek(profile: Profile, weekOf: Date, templatesByID: [String: QuestTemplate]) async throws -> Int64 {
        let familyCache = cacheService.fetchFamily(recordName: profile.family.recordID.recordName)
        let payoutDay = PayoutDayResolver.resolved(for: profile, family: familyCache)
        let normalizedWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: payoutDay)
        let logs = try await fetchQuestLogs(for: profile)
            .filter { $0.weekOf == normalizedWeek
                && ($0.verificationStatus == .autoApproved
                    || $0.verificationStatus == .verified)
            }

        guard !logs.isEmpty else { return 0 }
        let quests = try await fetchQuestsForLogs(logs, family: appState.family)
        // WHY day count wins: stale targetCount under-counts specific-days split rewards.
        return GoldCalculation.totalCreditPennies(for: quests, logs: logs, templatesByID: templatesByID)
    }

    private func fetchQuestsForLogs(
        _ logs: [QuestCompletion],
        family: Family?
    ) async throws -> [Quest] {
        guard !logs.isEmpty else { return [] }
        guard let family else { return [] }
        let needed = Set(logs.map(\.quest.recordID.recordName))
        let cache = cacheService
        let familyName = family.id.recordName
        let scope: CKDatabase.Scope = appState.activeDatabaseScope
        let isAuthoritative = cache.isCacheAuthoritative(familyRecordName: familyName, type: .quest, scope: scope)
        let zoneID = family.id.zoneID
        // WHY shared stitch: missing-key patch rides CacheFirst so payout
        // and log paths cannot drift; no cache writes, ingest() untouched.
        return try await CacheFirst.resolveWithCache(
            needed: needed,
            isAuthoritative: isAuthoritative,
            fetchCached: { cache.fetchQuests(family: familyName).map { $0.toQuest(zoneID: zoneID) } },
            fetchMissing: { [self] missingNames in
                try await self.fetchMissingQuestsForLogs(missingNames: missingNames, family: family)
            }
        )
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
            await syncCoordinator.hydrateFromQuery(
                models: all,
                databaseScope: appState.activeDatabaseScope,
                zoneID: quest.id.zoneID
            )
            return all
        }
        let family = Family(
            name: "",
            creatorUserRecordName: nil,
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
                await syncCoordinator.hydrateFromQuery(
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
            creatorUserRecordName: nil,
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
                await syncCoordinator.hydrateFromQuery(
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
                await syncCoordinator.hydrateFromQuery(
                    models: models,
                    databaseScope: appState.activeDatabaseScope,
                    zoneID: family.id.zoneID
                )
            }
        )
    }
}
