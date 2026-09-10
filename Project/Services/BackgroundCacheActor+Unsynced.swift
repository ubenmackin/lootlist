//
//  BackgroundCacheActor+Unsynced.swift
//  LootList
//
//  Created by Ben Mackin on 9/9/26.
//

import CloudKit
import Foundation
import os
import SwiftData

extension BackgroundCacheActor {
    // MARK: - Unsynced re-enqueue (off-main fetch)

    /// Fetches recordNames for locally-created rows that have never synced
    /// (changeTag == nil/empty). Runs on the background ModelContext under
    /// SerialMutationQueue so reconciliation and payout mutations cannot
    /// interleave the scan. Predicate pushdown keeps family tables indexed;
    /// results are sorted by recordName for deterministic enqueue ordering.
    func fetchUnsyncedRecordIDs(familyRecordName: String, zoneID: CKRecordZone.ID) async -> [CKRecord.ID] {
        await mutationQueue.write {
            await self.collectUnsyncedRecordIDs(familyRecordName: familyRecordName, zoneID: zoneID)
        }
    }

    private func pendingQuestNames(familyRecordName: String) -> Set<String> {
        let target = familyRecordName
        let descriptor = FetchDescriptor<QuestCache>(predicate: #Predicate { $0.familyRecordName == target && ($0.changeTag == nil || $0.changeTag == "") })
        do {
            return try Set(modelContext.fetch(descriptor).map(\.recordName))
        } catch {
            logger.error("Failed to fetch QuestCache for pending scan: \(error, privacy: .private)")
            return []
        }
    }

    private func pendingQuestTemplateNames(familyRecordName: String) -> Set<String> {
        let target = familyRecordName
        let descriptor = FetchDescriptor<QuestTemplateCache>(predicate: #Predicate { $0.familyRecordName == target && ($0.changeTag == nil || $0.changeTag == "") })
        do {
            return try Set(modelContext.fetch(descriptor).map(\.recordName))
        } catch {
            logger.error("Failed to fetch QuestTemplateCache for pending scan: \(error, privacy: .private)")
            return []
        }
    }

    private func pendingGoalNames(familyRecordName: String) -> Set<String> {
        let target = familyRecordName
        let descriptor = FetchDescriptor<GoalCache>(predicate: #Predicate { $0.familyRecordName == target && ($0.changeTag == nil || $0.changeTag == "") })
        do {
            return try Set(modelContext.fetch(descriptor).map(\.recordName))
        } catch {
            logger.error("Failed to fetch GoalCache for pending scan: \(error, privacy: .private)")
            return []
        }
    }

    private func pendingQuestCompletionNames(familyRecordName: String) -> Set<String> {
        let target = familyRecordName
        let descriptor = FetchDescriptor<QuestCompletionCache>(predicate: #Predicate { $0.familyRecordName == target && ($0.changeTag == nil || $0.changeTag == "") })
        do {
            return try Set(modelContext.fetch(descriptor).map(\.recordName))
        } catch {
            logger.error("Failed to fetch QuestCompletionCache for pending scan: \(error, privacy: .private)")
            return []
        }
    }

    private func pendingLedgerEntryNames(familyRecordName: String) -> Set<String> {
        let target = familyRecordName
        let descriptor = FetchDescriptor<LedgerEntryCache>(predicate: #Predicate { $0.familyRecordName == target && ($0.changeTag == nil || $0.changeTag == "") })
        do {
            return try Set(modelContext.fetch(descriptor).map(\.recordName))
        } catch {
            logger.error("Failed to fetch LedgerEntryCache for pending scan: \(error, privacy: .private)")
            return []
        }
    }

    private func pendingProfileNames(familyRecordName: String) -> Set<String> {
        let target = familyRecordName
        let descriptor = FetchDescriptor<ProfileCache>(predicate: #Predicate { $0.familyRecordName == target && ($0.changeTag == nil || $0.changeTag == "") })
        do {
            return try Set(modelContext.fetch(descriptor).map(\.recordName))
        } catch {
            logger.error("Failed to fetch ProfileCache for pending scan: \(error, privacy: .private)")
            return []
        }
    }

    private func pendingAllowancePeriodNames(familyRecordName: String) -> Set<String> {
        let target = familyRecordName
        let descriptor = FetchDescriptor<AllowancePeriodCache>(predicate: #Predicate { $0.familyRecordName == target && ($0.changeTag == nil || $0.changeTag == "") })
        do {
            return try Set(modelContext.fetch(descriptor).map(\.recordName))
        } catch {
            logger.error("Failed to fetch AllowancePeriodCache for pending scan: \(error, privacy: .private)")
            return []
        }
    }

    private func pendingAchievementNames(familyRecordName: String) -> Set<String> {
        let target = familyRecordName
        let descriptor = FetchDescriptor<AchievementCache>(predicate: #Predicate { $0.familyRecordName == target && ($0.changeTag == nil || $0.changeTag == "") })
        do {
            return try Set(modelContext.fetch(descriptor).map(\.recordName))
        } catch {
            logger.error("Failed to fetch AchievementCache for pending scan: \(error, privacy: .private)")
            return []
        }
    }

    private func pendingProfileAchievementNames(familyRecordName: String) -> Set<String> {
        let target = familyRecordName
        let descriptor = FetchDescriptor<ProfileAchievementCache>(predicate: #Predicate { $0.familyRecordName == target && ($0.changeTag == nil || $0.changeTag == "") })
        do {
            return try Set(modelContext.fetch(descriptor).map(\.recordName))
        } catch {
            logger.error("Failed to fetch ProfileAchievementCache for pending scan: \(error, privacy: .private)")
            return []
        }
    }

    private func pendingNotificationPreferenceNames(familyRecordName: String) -> Set<String> {
        let target = familyRecordName
        let descriptor = FetchDescriptor<NotificationPreferenceCache>(predicate: #Predicate { $0.familyRecordName == target && ($0.changeTag == nil || $0.changeTag == "") })
        do {
            return try Set(modelContext.fetch(descriptor).map(\.recordName))
        } catch {
            logger.error("Failed to fetch NotificationPreferenceCache for pending scan: \(error, privacy: .private)")
            return []
        }
    }

    private func pendingGemLedgerNames(familyRecordName: String) -> Set<String> {
        let target = familyRecordName
        let descriptor = FetchDescriptor<GemLedgerCache>(predicate: #Predicate { $0.familyRecordName == target && ($0.changeTag == nil || $0.changeTag == "") })
        do {
            return try Set(modelContext.fetch(descriptor).map(\.recordName))
        } catch {
            logger.error("Failed to fetch GemLedgerCache for pending scan: \(error, privacy: .private)")
            return []
        }
    }

    private func pendingRewardEventNames(familyRecordName: String) -> Set<String> {
        let target = familyRecordName
        let descriptor = FetchDescriptor<RewardEventCache>(predicate: #Predicate { $0.familyRecordName == target && ($0.changeTag == nil || $0.changeTag == "") })
        do {
            return try Set(modelContext.fetch(descriptor).map(\.recordName))
        } catch {
            logger.error("Failed to fetch RewardEventCache for pending scan: \(error, privacy: .private)")
            return []
        }
    }

    private func pendingFamilyNames(familyRecordName: String) -> Set<String> {
        let target = familyRecordName
        let descriptor = FetchDescriptor<FamilyCache>(predicate: #Predicate { $0.recordName == target && ($0.changeTag == nil || $0.changeTag == "") })
        do {
            return try Set(modelContext.fetch(descriptor).map(\.recordName))
        } catch {
            logger.error("Failed to fetch FamilyCache for pending scan: \(error, privacy: .private)")
            return []
        }
    }

    // WHY: Single pending-scan home so re-enqueue and reconcile preservation agree on what survives a snapshot.
    func collectPendingNames(familyRecordName: String) -> [CachedRecordType: Set<String>] {
        var pending: [CachedRecordType: Set<String>] = [:]
        func store(_ type: CachedRecordType, _ names: Set<String>) {
            guard !names.isEmpty else { return }
            pending[type] = names
        }
        // WHY indexed predicates: family+changeTag filters push to SQLite so 1500-ledger tables never materialize fully.
        store(.quest, pendingQuestNames(familyRecordName: familyRecordName))
        store(.questTemplate, pendingQuestTemplateNames(familyRecordName: familyRecordName))
        store(.goal, pendingGoalNames(familyRecordName: familyRecordName))
        store(.questCompletion, pendingQuestCompletionNames(familyRecordName: familyRecordName))
        store(.ledgerEntry, pendingLedgerEntryNames(familyRecordName: familyRecordName))
        store(.profile, pendingProfileNames(familyRecordName: familyRecordName))
        store(.allowancePeriod, pendingAllowancePeriodNames(familyRecordName: familyRecordName))
        store(.achievement, pendingAchievementNames(familyRecordName: familyRecordName))
        store(.profileAchievement, pendingProfileAchievementNames(familyRecordName: familyRecordName))
        store(.notificationPreference, pendingNotificationPreferenceNames(familyRecordName: familyRecordName))
        store(.gemLedger, pendingGemLedgerNames(familyRecordName: familyRecordName))
        store(.rewardEvent, pendingRewardEventNames(familyRecordName: familyRecordName))
        store(.family, pendingFamilyNames(familyRecordName: familyRecordName))
        return pending
    }

    private func collectUnsyncedRecordIDs(familyRecordName: String, zoneID: CKRecordZone.ID) async -> [CKRecord.ID] {
        let grouped = collectPendingNames(familyRecordName: familyRecordName)
        var ids: [CKRecord.ID] = []
        // WHY pre-size: offline days batch 1500 ledgers, so reserve once to avoid reallocation churn.
        ids.reserveCapacity(grouped.values.reduce(0) { $0 + $1.count })
        for names in grouped.values {
            for name in names {
                ids.append(CKRecord.ID(recordName: name, zoneID: zoneID))
            }
        }
        // Deterministic ordering so paging cap is stable across passes.
        ids.sort { $0.recordName < $1.recordName }
        return ids
    }
}
