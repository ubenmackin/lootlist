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

    func earnedThisWeek(profile: Profile, weekOf: Date) async throws -> Double {
        let payoutDay = effectivePayoutDay(for: profile)
        let normalizedWeek = QuestService.startOfWeek(for: weekOf, payoutDay: payoutDay)
        let logs = try await fetchQuestLogs(for: profile)
            .filter { $0.weekOf == normalizedWeek
                && ($0.verificationStatus == .autoApproved
                    || $0.verificationStatus == .verified)
            }

        guard !logs.isEmpty else { return 0 }

        let questIDs = Array(Set(logs.map(\.quest.recordID)))
        var questMap: [CKRecord.ID: Quest] = [:]

        // Cache-first: build a lookup dictionary from the family's cached
        // quests.  Only quest IDs absent from the cache fall through to the
        // per-ID CloudKit fetch below (genuine cache miss).
        if let cache = cacheService,
           let familyName = logs.first?.family.recordID.recordName
        {
            let zoneID = cloudKit.resolvedZoneID
            for row in cache.fetchQuests(family: familyName) {
                let quest = row.toQuest(zoneID: zoneID)
                questMap[quest.id] = quest
            }
        }

        let missingIDs = questIDs.filter { questMap[$0] == nil }

        // CK fallback ONLY for cache-miss IDs (gracefully skipping deleted/missing quests).
        for questID in missingIDs {
            if let fetched = try? await cloudKit.fetch(Quest.self, id: questID) {
                questMap[questID] = fetched
            }
        }

        // Group approved logs by quest and route gold credit through the
        // shared `GoldCalculation` helper — the same one
        // `TreasuryService.sumGold` uses — so this weekly total and the wallet
        // never disagree on a partially completed quest. The proration is
        // per-quest (approvedCount per quest * goldReward / targetCount,
        // capped by `isAllOrNothing`), so the helper is invoked once per
        // quest with the full approved count for that quest.
        var approvedCountByQuest: [CKRecord.ID: Int] = [:]
        for log in logs {
            approvedCountByQuest[log.quest.recordID, default: 0] += 1
        }

        var total: Double = 0
        for (questID, questCount) in approvedCountByQuest {
            if let quest = questMap[questID] {
                total += GoldCalculation.creditAsDouble(for: quest,
                                                        approvedCount: questCount)
            }
        }
        return total
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    func fetchQuestLogs(forQuest quest: Quest, useCache: Bool = true) async throws -> [QuestCompletion] {
        if useCache, let cache = cacheService {
            let questName = quest.id.recordName
            let familyName = quest.family.recordID.recordName
            let cached = cache.fetchQuestCompletions(family: familyName)
                .filter { $0.questRecordName == questName }
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .questCompletion) {
                return cached.map { $0.toQuestCompletion(zoneID: cloudKit.resolvedZoneID) }
                    .sorted { $0.completedDate > $1.completedDate }
            }
        }

        let questRef = CKRecord.Reference(recordID: quest.id, action: .none)
        let predicate = NSPredicate(format: "quest == %@", questRef)
        let all = try await cloudKit.query(
            QuestCompletion.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
        )
        cacheService?.upsertQuestCompletions(all, family: quest.family.recordID.recordName)
        return all
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    func fetchQuestLogs(for profile: Profile) async throws -> [QuestCompletion] {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchQuestCompletions(family: familyName)
                .filter { $0.completerRecordName == profileName }
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .questCompletion) {
                return cached.map { $0.toQuestCompletion(zoneID: cloudKit.resolvedZoneID) }
                    .sorted { $0.completedDate > $1.completedDate }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let pred = NSPredicate(format: "completedBy == %@", profileRef)
        let all = try await cloudKit.query(
            QuestCompletion.self,
            predicate: pred,
            sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
        )
        cacheService?.upsertQuestCompletions(all, family: profile.family.recordID.recordName)
        return all
    }

    // MARK: - Batch Fetch

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    func fetchQuestCompletionsForFamily(family: Family) async throws -> [QuestCompletion] {
        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchQuestCompletions(family: familyName)
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .questCompletion) {
                let zoneID = cloudKit.resolvedZoneID
                return cached.map { $0.toQuestCompletion(zoneID: zoneID) }
            }
        }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let completions = try await cloudKit.query(
            QuestCompletion.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
        )
        cacheService?.upsertQuestCompletions(completions, family: family.id.recordName)
        return completions
    }
}
