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

        return await GoldCalculation.totalCredit(
            logs: logs,
            cacheService: cacheService,
            cloudKit: cloudKit,
            family: appState?.family
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
        cacheService?.upsertQuestCompletions(all, family: quest.family.recordID.recordName)
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
        cacheService?.upsertQuestCompletions(all, family: profile.family.recordID.recordName)
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
        cacheService?.upsertQuestCompletions(completions, family: family.id.recordName)
        return completions
    }
}
