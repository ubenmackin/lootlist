//
//  TreasuryServiceRealTimeTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct TreasuryServiceRealTimeTests {
    /// Shared fixtures for `processRealTimeSettlement` tests.
    ///
    /// A `.realTime` hero in a Sunday-cycle family, with the payout week
    /// normalized to Monday. The hero is seeded into the CloudKit mock store
    /// so the mock path is active AND `updateAllowance`'s profile re-fetch
    /// resolves; quest/completion reads ride the cache-first path when
    /// `seedEarned` is used.
    @MainActor
    struct SettlementScaffold {
        let zoneID: CKRecordZone.ID
        let cloudKit: CloudKitService
        let cache: CacheService
        let treasury: TreasuryService
        let profile: Profile
        let family: Family
        let weekOf: Date

        init() throws {
            zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
            cloudKit = CloudKitService(zoneID: zoneID)
            cache = try CacheService(inMemory: true)
            treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache)

            let familyRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
            )
            let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
            profile = Profile(
                displayName: "Hero",
                avatarClass: .mage,
                avatarPresetID: "mage_01",
                role: .hero,
                iCloudUserID: heroID,
                family: familyRef,
                payoutPolicy: .realTime,
                id: heroID
            )
            family = Family(
                name: "Test Guild",
                createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
                payoutDay: .sunday,
                id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
            )
            weekOf = WeekMath.mondayOfWeek(for: Date())

            cloudKit.seedMockRecords([profile])
        }

        func quest(goldReward: Double = 25.0) -> Quest {
            Quest(
                template: CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
                ),
                assignee: CKRecord.Reference(recordID: profile.id, action: .none),
                goldReward: goldReward,
                xpReward: 50,
                scheduleType: .weeklyFlexible,
                targetCount: 1,
                isAllOrNothing: false,
                approvalMode: .autoApprove,
                weekOf: weekOf,
                createdBy: CKRecord.Reference(recordID: family.id, action: .none),
                family: CKRecord.Reference(recordID: family.id, action: .none),
                name: "Settle Quest",
                id: CKRecord.ID(recordName: "quest1", zoneID: zoneID)
            )
        }

        func completion(recordName: String = "log1") -> QuestCompletion {
            QuestCompletion(
                quest: CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: "quest1", zoneID: zoneID), action: .none
                ),
                completedBy: CKRecord.Reference(recordID: profile.id, action: .none),
                approvalMode: .autoApprove,
                weekOf: weekOf,
                family: CKRecord.Reference(recordID: family.id, action: .none),
                id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
            )
        }

        /// Seeds an approved completion for the current week into the cache so
        /// `weeklyBreakdown`'s cache-first gates serve it deterministically.
        func seedEarned(goldReward: Double = 25.0) {
            cache.upsertQuest(quest(goldReward: goldReward))
            cache.upsertQuestCompletions([completion()])
            cache.markCacheFresh(familyRecordName: family.id.recordName, type: .questCompletion)
        }

        func settle() async throws -> AllowancePeriod? {
            try await treasury.processRealTimeSettlement(
                profile: profile,
                family: family,
                date: weekOf
            )
        }
    }

    @Test
    func `real time settlement persists fresh quest totals`() async throws {
        let scaffold = try SettlementScaffold()
        scaffold.seedEarned()

        let settled = try await scaffold.settle()
        let period = try #require(settled)

        #expect(period.totalEarned == 25.0, "Fresh quest gold must land on the period")
        #expect(period.questsCompleted == 1, "Fresh completed-quest count must land on the period")
        #expect(period.paidAmount == 25.0, "paidAmount must mirror the settled gold")
        #expect(period.paidDate != nil, "Settlement must stamp a paid date")

        // The persisted period carries the same fresh totals.
        let cached = scaffold.cache
            .fetchAllowancePeriods(family: scaffold.family.id.recordName).first
        let persisted = try #require(cached?.toAllowancePeriod(zoneID: scaffold.zoneID))
        #expect(persisted.totalEarned == 25.0)
        #expect(persisted.questsCompleted == 1)
    }

    @Test
    func `repeated real time settlements do not double count gold`() async throws {
        let scaffold = try SettlementScaffold()
        scaffold.seedEarned()

        let firstResult = try await scaffold.settle()
        let first = try #require(firstResult)
        let secondResult = try await scaffold.settle()
        let second = try #require(secondResult)

        #expect(first.totalEarned == 25.0)
        #expect(second.totalEarned == 25.0, "A second settlement must not double the gold")
        #expect(second.questsCompleted == 1)
        #expect(second.paidAmount == 25.0)

        // Exactly one period exists for the hero's week.
        let periods = await scaffold.treasury.fetchAllowancePeriods(family: scaffold.family)
        #expect(periods.count == 1)
    }

    @Test
    func `real time settlement keeps the period open and unclosed`() async throws {
        let scaffold = try SettlementScaffold()
        scaffold.seedEarned()

        let settled = try await scaffold.settle()
        let period = try #require(settled)

        #expect(period.status == .active, "Real-time settlement must not close the period")
        #expect(period.paidAmount == 25.0, "Settlement markers are written without closing")
        #expect(period.paidDate != nil)
    }

    @Test
    func `real time settlement with zero earnings leaves no phantom totals`() async throws {
        let scaffold = try SettlementScaffold()

        let settled = try await scaffold.settle()
        let period = try #require(settled)

        #expect(period.totalEarned == 0, "Zero-earning settlement must not fabricate totals")
        #expect(period.questsCompleted == 0)
        #expect(period.paidAmount == 0)
        #expect(period.status == .active)
    }
}
