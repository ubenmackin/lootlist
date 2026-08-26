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

        let daySet: Set<Date> = Set(logs.compactMap { log -> Date? in
            guard log.verificationStatus == .autoApproved || log.verificationStatus == .verified else { return nil }
            return calendar.dateInterval(of: .day, for: log.completedDate)?.start
        })

        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let anchor = daySet.contains(today) ? today
            : (daySet.contains(yesterday) ? yesterday : nil)
        guard let anchor else { return 0 }

        var streak = 0
        var cursor = anchor

        while daySet.contains(cursor) {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return streak
    }

    /// Authoritative week earnings for the wallet. Pure `GoldCalculation` math
    /// over already-fetched quests — no CloudKit access inside the math util.
    ///
    /// - Throws: Re-throws `fetchQuestLogs` / quest-fetch CloudKit errors.
    ///   Callers must handle with `do { try await ... } catch` + toast + retry.
    ///   Cache-only callers should use `HeroDashboardViewModel.earnedThisWeek`
    ///   / `GoldCalculation.netWeeklyGold` instead, which are `sync`/`non-throwing`.
    func earnedThisWeek(profile: Profile, weekOf: Date) async throws -> Double {
        let payoutDay = effectivePayoutDay(for: profile)
        let normalizedWeek = QuestService.startOfWeek(for: weekOf, payoutDay: payoutDay)
        let logs = try await fetchQuestLogs(for: profile)
            .filter { $0.weekOf == normalizedWeek
                && ($0.verificationStatus == .autoApproved
                    || $0.verificationStatus == .verified)
            }

        guard !logs.isEmpty else { return 0 }
        let quests = try await fetchQuestsForLogs(logs, family: appState?.family)
        return GoldCalculation.totalCredit(for: quests, logs: logs)
    }

    private func fetchQuestsForLogs(
        _ logs: [QuestCompletion],
        family: Family?
    ) async throws -> [Quest] {
        guard !logs.isEmpty else { return [] }
        let needed = Set(logs.map(\.quest.recordID.recordName))
        if let cache = cacheService, let family {
            let familyName = family.id.recordName
            let isFresh = await MainActor.run {
                cache.isCacheFresh(familyRecordName: familyName, type: .quest)
            }
            if isFresh {
                let zoneID = family.id.zoneID
                let cached = await MainActor.run {
                    cache.fetchQuests(family: familyName).map { $0.toQuest(zoneID: zoneID) }
                }
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
        if useCache, let cache = cacheService {
            let questName = quest.id.recordName
            let familyName = quest.family.recordID.recordName
            let cached = cache.fetchQuestCompletions(family: familyName)
                .filter { $0.questRecordName == questName }
            if cache.isCacheFresh(familyRecordName: familyName, type: .questCompletion) {
                return cached.map { $0.toQuestCompletion(zoneID: quest.id.zoneID) }
                    .sorted { $0.completedDate > $1.completedDate }
            }
        }

        let questRef = CKRecord.Reference(recordID: quest.id, action: .none)
        let predicate = NSPredicate(format: "quest == %@", questRef)
        let all = try await cloudKit.query(
            QuestCompletion.self,
            predicate: predicate,
            in: quest.id.zoneID,
            sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
        )
        if let syncCoordinator {
            await syncCoordinator.delegateHandler.hydrateFromQuery(
                models: all,
                databaseScope: appState?.isZoneOwner == true ? .private : .shared,
                zoneID: quest.id.zoneID
            )
        } else {
            await cacheService?.upsertQuestCompletions(all, family: quest.family.recordID.recordName)
        }
        return all
    }

    /// Cache-first read. Background refresh handled by CKSyncEngine via push notifications.
    func fetchQuestLogs(for profile: Profile) async throws -> [QuestCompletion] {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchQuestCompletions(family: familyName)
                .filter { $0.completerRecordName == profileName }
            if cache.isCacheFresh(familyRecordName: familyName, type: .questCompletion) {
                return cached.map { $0.toQuestCompletion(zoneID: profile.id.zoneID) }
                    .sorted { $0.completedDate > $1.completedDate }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let pred = NSPredicate(format: "completedBy == %@", profileRef)
        let all = try await cloudKit.query(
            QuestCompletion.self,
            predicate: pred,
            in: profile.id.zoneID,
            sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
        )
        if let syncCoordinator {
            await syncCoordinator.delegateHandler.hydrateFromQuery(
                models: all,
                databaseScope: appState?.isZoneOwner == true ? .private : .shared,
                zoneID: profile.id.zoneID
            )
        } else {
            await cacheService?.upsertQuestCompletions(all, family: profile.family.recordID.recordName)
        }
        return all
    }

    // MARK: - Batch Fetch

    /// Cache-first read. Background refresh handled by CKSyncEngine via push notifications.
    func fetchQuestCompletionsForFamily(family: Family) async throws -> [QuestCompletion] {
        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchQuestCompletions(family: familyName)
            if cache.isCacheFresh(familyRecordName: familyName, type: .questCompletion) {
                return cached.map { $0.toQuestCompletion(zoneID: family.id.zoneID) }
            }
        }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let completions = try await cloudKit.query(
            QuestCompletion.self,
            predicate: predicate,
            in: family.id.zoneID,
            sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
        )
        if let syncCoordinator {
            await syncCoordinator.delegateHandler.hydrateFromQuery(
                models: completions,
                databaseScope: appState?.isZoneOwner == true ? .private : .shared,
                zoneID: family.id.zoneID
            )
        } else {
            await cacheService?.upsertQuestCompletions(completions, family: family.id.recordName)
        }
        return completions
    }
}
