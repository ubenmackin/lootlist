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
    // MARK: - Pending-log withdrawal is state-based (append-only, no hard delete)

    @Test
    func `withdrawCompletion keeps the record inserted and marks it withdrawn`() async throws {
        // Unsubmitting a pending completion is a state transition
        // (pending → withdrawn), never a CloudKit delete — QuestCompletions
        // are append-only, so the record must survive the withdrawal.
        let scaffold = try MarkCompleteScaffold()
        let pending = scaffold.completion(status: .pending)
        scaffold.cache.upsertQuestCompletion(pending)
        scaffold.cloudKit.seedMockRecords([pending])

        try await scaffold.questService.withdrawCompletion(questLog: pending, by: scaffold.hero)

        // Append-only invariant: the record still exists in CloudKit with the
        // withdrawn state instead of being hard-deleted.
        let server = try await scaffold.cloudKit.fetch(QuestCompletion.self, id: pending.id)
        #expect(
            server.verificationStatus == .withdrawn,
            "A withdrawn completion must stay in CloudKit, marked withdrawn"
        )

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
    func `withdrawCompletion failure restores the pending cache row instead of dropping it`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let scaffold = try MarkCompleteScaffold(cloudKitOverride: cloudKit)
        let pending = scaffold.completion(status: .pending)
        scaffold.cache.upsertQuestCompletion(pending)
        cloudKit.seedMockRecords([pending])
        cloudKit.saveError = CloudKitServiceError.networkUnavailable

        await #expect(throws: CloudKitServiceError.networkUnavailable) {
            try await scaffold.questService.withdrawCompletion(questLog: pending, by: scaffold.hero)
        }

        // The cache must still hold the record — restored to pending — not be
        // invalidated by the failed withdrawal.
        let cached = try #require(
            scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName)
                .first { $0.recordName == pending.id.recordName },
            "A failed withdrawal must leave the cached completion in place"
        )
        #expect(
            cached.verificationStatus == VerificationStatus.pending.rawValue,
            "A failed withdrawal must restore the pending state in the cache"
        )

        // The server record is untouched: still present, still pending.
        let server = try await cloudKit.fetch(QuestCompletion.self, id: pending.id)
        #expect(server.verificationStatus == .pending)
    }

    @Test
    func `withdrawn completion frees the quest slot for a new submission`() async throws {
        let scaffold = try MarkCompleteScaffold()
        let pending = scaffold.completion(status: .pending)
        scaffold.cache.upsertQuestCompletion(pending)
        scaffold.cloudKit.seedMockRecords([pending])

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
            "The withdrawn log must remain in the cache append-only"
        )
    }
}
