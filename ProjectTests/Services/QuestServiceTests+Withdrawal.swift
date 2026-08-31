//
//  QuestServiceTests+Withdrawal.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

extension QuestServiceTests {
    // MARK: - Pending-log withdrawal is state-based (mutable status transition, no hard delete)

    @Test
    func `withdrawCompletion keeps the record inserted and marks it withdrawn`() async throws {
        // Unsubmitting a pending completion is a state transition
        // (pending → withdrawn), never a hard delete — QuestCompletions
        // use mutable status transitions, so the record must survive the withdrawal.
        let scaffold = try MarkCompleteScaffold()
        let pending = scaffold.completion(status: .pending)
        await scaffold.cache.upsertQuestCompletion(pending)

        try await scaffold.questService.withdrawCompletion(questLog: pending, by: scaffold.hero)

        // The local cache mirrors the withdrawn state.
        let cached = try #require(
            scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName)
                .first { $0.recordName == pending.id.recordName }
        )
        #expect(
            cached.verificationStatus == VerificationStatus.withdrawn.rawValue,
            "The cache must mirror the withdrawn completion"
        )
    }

    @Test
    func `withdrawCompletion updates local cache immediately`() async throws {
        let scaffold = try MarkCompleteScaffold()
        let pending = scaffold.completion(status: .pending)
        await scaffold.cache.upsertQuestCompletion(pending)

        try await scaffold.questService.withdrawCompletion(questLog: pending, by: scaffold.hero)

        let cached = try #require(
            scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName)
                .first { $0.recordName == pending.id.recordName },
            "A withdrawal must leave the cached completion in place"
        )
        #expect(
            cached.verificationStatus == VerificationStatus.withdrawn.rawValue,
            "A withdrawal must mark the completion withdrawn in cache"
        )
    }

    @Test
    func `withdrawn completion frees the quest slot for a new submission`() async throws {
        let scaffold = try MarkCompleteScaffold()
        let pending = scaffold.completion(status: .pending)
        await scaffold.cache.upsertQuestCompletion(pending)
        scaffold.seedMockRecords([pending])

        try await scaffold.questService.withdrawCompletion(questLog: pending, by: scaffold.hero)

        // The withdrawn log occupies no slot, so a fresh submission proceeds.
        let saved = try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)
        #expect(saved.verificationStatus == .pending)

        let logs = scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName)
            .filter { $0.questRecordName == scaffold.quest.id.recordName }
        #expect(
            logs.count == 2,
            "Withdrawn log (does not count) + new completion = 2 logs for the quest"
        )
        #expect(
            logs.contains { $0.verificationStatus == VerificationStatus.withdrawn.rawValue },
            "The withdrawn log must remain in the cache as a status-transitioned record"
        )
    }

    // MARK: - Bucket overdraft rejection

    @Test
    func `bucket transfer rejects overdrawing the source bucket`() async throws {
        let scaffold = try MarkCompleteScaffold()
        let cache = scaffold.cache

        func seedEntry(_ name: String, amount: Double, kind: BucketKind) {
            cache.context?.insert(LedgerEntryCache(from: LedgerEntry(
                profile: CKRecord.Reference(recordID: scaffold.hero.id, action: .none),
                amount: amount,
                description: name,
                date: Date(),
                source: "quest",
                bucketKind: kind.rawValue,
                family: scaffold.familyRef,
                id: CKRecord.ID(recordName: name, zoneID: scaffold.zoneID)
            )))
            _ = cache.saveContext()
        }
        seedEntry("seed-spend", amount: 5.00, kind: .spend)
        seedEntry("seed-short", amount: 2.00, kind: .shortTermSave)

        let conflictResolver = CKSyncConflictResolver(cacheService: cache, appState: scaffold.appState)
        let delegateHandler = CKSyncEngineDelegateHandler(
            conflictResolver: conflictResolver,
            cacheService: cache,
            appState: scaffold.appState
        )
        let syncCoordinator = CKSyncEngineCoordinator(
            cloudKitService: scaffold.cloudKit,
            delegateHandler: delegateHandler,
            appState: scaffold.appState,
            defaults: UserDefaults.ephemeral()
        )
        let buckets = BucketService(cacheService: cache, syncCoordinator: syncCoordinator, appState: scaffold.appState)
        let family = try #require(scaffold.appState.family)
        let transferID = BucketService.deterministicTransferID(
            dayBucket: WeekMath.dayBucket(for: Date()),
            from: .spend,
            to: .shortTermSave
        )

        await #expect(throws: BucketServiceError.insufficientFunds(available: 5.00, requested: 7.00)) {
            try await buckets.transfer(
                from: .spend,
                to: .shortTermSave,
                amount: 7.00,
                profile: scaffold.hero,
                family: family,
                transferID: transferID
            )
        }

        // The rejected transfer leaves balances and the ledger untouched —
        // no partial movement may be recorded.
        let balances = buckets.bucketBalances(
            profileRecordName: scaffold.hero.id.recordName,
            familyRecordName: family.id.recordName
        )
        #expect(balances[.spend] == 5.00)
        #expect(balances[.shortTermSave] == 2.00)
        let rows = cache.fetchLedgerEntries(
            profileRecordName: scaffold.hero.id.recordName,
            family: family.id.recordName
        )
        #expect(!rows.contains { $0.source == "transfer" })
    }
}
