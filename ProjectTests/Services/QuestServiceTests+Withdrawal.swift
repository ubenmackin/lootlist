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
        scaffold.cache.upsertQuestCompletion(pending)

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
        scaffold.cache.upsertQuestCompletion(pending)

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
            "The withdrawn log must remain in the cache as a status-transitioned record"
        )
    }
}
