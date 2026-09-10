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
    // MARK: - Pending re-enqueue (off-main fetch)

    /// Result of the overflow-aware pending scan.
    struct PendingRecordScan: Sendable {
        /// Never-synced rows plus tracked overflow saves whose cache row still exists.
        let recordIDsToEnqueue: [CKRecord.ID]
        /// Tracked overflow deletes still owed to CloudKit; they must be handed to an active engine as deletes.
        let deleteRecordIDsToEnqueue: [CKRecord.ID]
        /// Tracked overflow deletes superseded by a newer write for the same identity — the newer write wins,
        /// so the delete must be dropped from recovery rather than re-issued.
        let supersededDeleteRecordIDs: Set<CKRecord.ID>
        /// Tracked overflow saves with no cache row — locally deleted, so a dropped save is moot.
        let confirmedDeletedRecordIDs: Set<CKRecord.ID>
    }

    /// WHY overflow-aware: the never-synced scan only returns rows with a nil/empty changeTag, so an evicted
    /// save for an already-synced row (non-nil changeTag) would look resolved. This scan also probes the
    /// tracked overflow identities, returning their rows for re-enqueue and treating only an absent row as
    /// resolved. Tracked deletes are never resolved by cache-row absence — that is a delete's normal state —
    /// so they return as deletes to hand back to an active engine. A tracked delete with a pending never-synced
    /// save for the same identity is superseded instead of re-issued, since the newer save wins. Runs on the
    /// background ModelContext under SerialMutationQueue like the never-synced scan.
    func fetchPendingRecordIDs(
        familyRecordName: String,
        zoneID: CKRecordZone.ID,
        trackedDroppedIdentities: [BufferOverflowIdentity]
    ) async -> PendingRecordScan {
        await mutationQueue.write {
            await self.collectPendingRecordScan(
                familyRecordName: familyRecordName,
                zoneID: zoneID,
                trackedDroppedIdentities: trackedDroppedIdentities
            )
        }
    }

    private func collectPendingRecordScan(
        familyRecordName: String,
        zoneID: CKRecordZone.ID,
        trackedDroppedIdentities: [BufferOverflowIdentity]
    ) async -> PendingRecordScan {
        let grouped = collectPendingNames(familyRecordName: familyRecordName)
        var names = Set(grouped.values.flatMap(\.self))
        var deleteNames: Set<String> = []
        var supersededDeletes: Set<CKRecord.ID> = []
        var confirmedDeleted: Set<CKRecord.ID> = []
        for tracked in trackedDroppedIdentities where !tracked.recordName.isEmpty {
            switch tracked.operation {
            case .delete:
                // WHY pending-save supersedes: a never-synced row for this identity is a newer local write,
                // so re-issuing the delete would destroy the re-created record. A server re-hydration carries
                // a changeTag and is absent here, so a pending delete is still honored for it.
                if names.contains(tracked.recordName) {
                    supersededDeletes.insert(CKRecord.ID(recordName: tracked.recordName, zoneID: zoneID))
                    continue
                }
                // WHY delete-specific: a delete's cache row is already gone, so absence is not recovery.
                deleteNames.insert(tracked.recordName)
            case .save:
                // WHY skip-known: a never-synced row is already pending, so only probe rows the changeTag scan cannot see.
                guard !names.contains(tracked.recordName) else { continue }
                if trackedRecordExists(name: tracked.recordName, familyRecordName: familyRecordName) {
                    names.insert(tracked.recordName)
                } else {
                    confirmedDeleted.insert(CKRecord.ID(recordName: tracked.recordName, zoneID: zoneID))
                }
            }
        }
        // Deterministic ordering so the paging cap slices a stable prefix.
        let ids = names
            .map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
            .sorted { $0.recordName < $1.recordName }
        let deleteIDs = deleteNames
            .map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
            .sorted { $0.recordName < $1.recordName }
        return PendingRecordScan(
            recordIDsToEnqueue: ids,
            deleteRecordIDsToEnqueue: deleteIDs,
            supersededDeleteRecordIDs: supersededDeletes,
            confirmedDeletedRecordIDs: confirmedDeleted
        )
    }

    /// WHY indexed probe: each tracked name resolves through recordName+family so no family table is scanned.
    /// WHY CachedRecordType-driven: the per-type dispatch lives in one table, so a new cache type cannot be
    /// forgotten here.
    private func trackedRecordExists(name: String, familyRecordName: String) -> Bool {
        for type in CachedRecordType.allCases where type.recordExists(
            in: modelContext,
            recordName: name,
            familyRecordName: familyRecordName
        ) {
            return true
        }
        return false
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
}
