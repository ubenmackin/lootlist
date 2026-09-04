//
//  CacheServicing.swift
//  LootList
//
//  Created by Ben Mackin on 8/28/26.
//

import CloudKit
import Foundation

/// Narrow seam over the local SwiftData cache. Exposes only the reads and
/// writes that domain services require so lightweight mocks can be injected
/// without carrying the full CacheService surface.
@MainActor
protocol CacheServicing: AnyObject {
    // MARK: - Reads

    func fetchLedgerEntries(profileRecordName: String, family: String?) -> [LedgerEntryCache]
    func fetchLedgerEntries(profileRecordName: String, family: String, recordNamePrefix: String) -> [LedgerEntryCache]
    func fetchTransfers(profileRecordName: String, familyRecordName: String, from fromRaw: String, to toRaw: String, dayBucket: Int) -> [LedgerEntryCache]
    func fetchLedgerEntry(recordName: String, family: String) -> LedgerEntryCache?
    func fetchProfiles(family: String?) -> [ProfileCache]
    func fetchProfile(recordName: String, family: String) -> ProfileCache?
    func fetchQuests(family: String?) -> [QuestCache]
    func fetchGoals(family: String?) -> [GoalCache]
    func fetchGoals(profileRecordName: String, bucketKind: String, familyRecordName: String) -> [GoalCache]
    func fetchGoal(recordName: String, family: String) -> GoalCache?
    func fetchFamily(recordName: String) -> FamilyCache?
    func fetchAllowancePeriod(recordName: String, family: String) -> AllowancePeriodCache?
    func fetchAllowancePeriods(profileRecordName: String, family: String?) -> [AllowancePeriodCache]
    func fetchAllowancePeriods(family: String?) -> [AllowancePeriodCache]
    func fetchQuestCompletions(family: String?) -> [QuestCompletionCache]
    func isCacheAuthoritative(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope) -> Bool

    // MARK: - Writes

    func upsertLedgerEntry(_ entry: LedgerEntry, family: String?, isServerSync: Bool) async
    func upsertAllowancePeriod(_ period: AllowancePeriod, family: String?, isServerSync: Bool) async
    func upsertGoal(_ goal: Goal, family: String?, isServerSync: Bool) async
    func upsertProfile(_ profile: Profile, family: String?, isServerSync: Bool) async
    func batchUpsertLedgerEntriesAndGoals(ledgerEntries: [LedgerEntry], goals: [Goal], familyRecordName: String?) async
    func invalidate(recordName: String, family: String, type: CachedRecordType) async
    func invalidate(identity: ScopedRecordIdentity, type: CachedRecordType, expectedActiveZone: CKRecordZone.ID?) async
}

@MainActor
extension CacheServicing {
    func invalidate(identity: ScopedRecordIdentity, type: CachedRecordType, expectedActiveZone _: CKRecordZone.ID?) async {
        guard let family = identity.familyRecordName else { return }
        await invalidate(recordName: identity.recordName, family: family, type: type)
    }

    func upsertLedgerEntry(_ entry: LedgerEntry) async {
        await upsertLedgerEntry(entry, family: nil, isServerSync: false)
    }

    func upsertLedgerEntry(_ entry: LedgerEntry, family: String?) async {
        await upsertLedgerEntry(entry, family: family, isServerSync: false)
    }

    func upsertGoal(_ goal: Goal) async {
        await upsertGoal(goal, family: nil, isServerSync: false)
    }

    func upsertGoal(_ goal: Goal, family: String?) async {
        await upsertGoal(goal, family: family, isServerSync: false)
    }

    func upsertProfile(_ profile: Profile) async {
        await upsertProfile(profile, family: nil, isServerSync: false)
    }

    func upsertProfile(_ profile: Profile, family: String?) async {
        await upsertProfile(profile, family: family, isServerSync: false)
    }

    func upsertAllowancePeriod(_ period: AllowancePeriod) async {
        await upsertAllowancePeriod(period, family: nil, isServerSync: false)
    }

    func upsertAllowancePeriod(_ period: AllowancePeriod, family: String?) async {
        await upsertAllowancePeriod(period, family: family, isServerSync: false)
    }

    func upsertAllowancePeriod(_ period: AllowancePeriod, isServerSync: Bool) async {
        await upsertAllowancePeriod(period, family: nil, isServerSync: isServerSync)
    }

    func batchUpsertLedgerEntriesAndGoals(ledgerEntries: [LedgerEntry], goals: [Goal]) async {
        await batchUpsertLedgerEntriesAndGoals(ledgerEntries: ledgerEntries, goals: goals, familyRecordName: nil)
    }
}
