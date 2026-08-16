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
        let cloudKit: any CloudKitServiceProtocol
        let cache: CacheService
        let appState: AppState
        let treasury: TreasuryService
        let profile: Profile
        let family: Family
        let weekOf: Date

        init() throws {
            zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
            let mock = MockCloudKitService()
            mock.activeFamilyZoneID = zoneID
            cloudKit = mock
            cache = try CacheService(inMemory: true)
            appState = AppState()
            // The real-time settlement guard accepts the hero themself OR a
            // parent acting on the hero's behalf — the hero self-settles an
            // auto-approved completion, while a parent settles on the
            // parent-verified path.
            treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache, appState: appState)

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
            appState.currentProfile = profile
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
            cache.markCacheFresh(familyRecordName: family.id.recordName, type: .allowancePeriod)
            cache.markCacheFresh(familyRecordName: family.id.recordName, type: .ledgerEntry)
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

    /// Shared fixtures for the real-time → week-end payout regression.
    ///
    /// A hero (policy parameterizable; `.realTime` by default) in a
    /// Sunday-cycle family, plus a Guild Master who finalizes the week with
    /// `runPayout`. Both tiers are seeded — the CloudKit mock store for the
    /// fetch paths and the in-memory cache with freshness stamps for the
    /// read-first gates — so the settlement and payout paths run
    /// deterministically off the cache.
    @MainActor
    struct PayoutScaffold {
        let zoneID: CKRecordZone.ID
        let cloudKit: any CloudKitServiceProtocol
        let cache: CacheService
        let appState: AppState
        let treasury: TreasuryService
        let hero: Profile
        let guildMaster: Profile
        let family: Family
        let weekOf: Date

        init(policy: PayoutPolicy = .realTime) throws {
            zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
            let mock = MockCloudKitService()
            mock.activeFamilyZoneID = zoneID
            cloudKit = mock
            cache = try CacheService(inMemory: true)
            appState = AppState()
            treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache, appState: appState)

            let familyRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
            )
            let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
            hero = Profile(
                displayName: "Hero",
                avatarClass: .mage,
                avatarPresetID: "mage_01",
                role: .hero,
                iCloudUserID: heroID,
                family: familyRef,
                payoutPolicy: policy,
                id: heroID
            )
            let gmID = CKRecord.ID(recordName: "gm1", zoneID: zoneID)
            guildMaster = Profile(
                displayName: "Guild Master",
                avatarClass: .knight,
                avatarPresetID: "knight_01",
                role: .guildMaster,
                iCloudUserID: gmID,
                family: familyRef,
                id: gmID
            )
            family = Family(
                name: "Test Guild",
                createdBy: gmID,
                payoutDay: .sunday,
                id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
            )
            weekOf = WeekMath.mondayOfWeek(for: Date())

            cloudKit.seedMockRecords([hero, guildMaster, family])
            cache.upsertProfile(hero)
            cache.upsertProfile(guildMaster)
            cache.upsertFamily(family)
            cache.markCacheFresh(familyRecordName: family.id.recordName, type: .profile)
            cache.markCacheFresh(familyRecordName: family.id.recordName, type: .family)
            appState.currentProfile = hero
        }

        /// Seeds an approved completion for the current week into the cache so
        /// `weeklyBreakdown`'s cache-first gates serve it deterministically.
        func seedEarned(goldReward: Double = 25.0) {
            let templateRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
            )
            let quest = Quest(
                template: templateRef,
                assignee: CKRecord.Reference(recordID: hero.id, action: .none),
                goldReward: goldReward,
                xpReward: 50,
                scheduleType: .weeklyFlexible,
                targetCount: 1,
                isAllOrNothing: false,
                approvalMode: .autoApprove,
                weekOf: weekOf,
                createdBy: CKRecord.Reference(recordID: family.id, action: .none),
                family: CKRecord.Reference(recordID: family.id, action: .none),
                name: "Payout Quest",
                id: CKRecord.ID(recordName: "quest1", zoneID: zoneID)
            )
            let completion = QuestCompletion(
                quest: CKRecord.Reference(recordID: quest.id, action: .none),
                completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
                approvalMode: .autoApprove,
                weekOf: weekOf,
                family: CKRecord.Reference(recordID: family.id, action: .none)
            )
            cache.upsertQuest(quest)
            cache.upsertQuestCompletions([completion])
            cache.markCacheFresh(familyRecordName: family.id.recordName, type: .quest)
            cache.markCacheFresh(familyRecordName: family.id.recordName, type: .questCompletion)
            cache.markCacheFresh(familyRecordName: family.id.recordName, type: .allowancePeriod)
            cache.markCacheFresh(familyRecordName: family.id.recordName, type: .ledgerEntry)
        }

        /// The hero self-settles their reward (the QuestService.applyReward
        /// real-time path), which mints the week's "rt-" ledger entry.
        func settle() async throws -> AllowancePeriod {
            appState.currentProfile = hero
            let settled = try await treasury.processRealTimeSettlement(
                profile: hero,
                family: family,
                date: weekOf
            )
            return try #require(settled)
        }

        /// The Guild Master finalizes the week's payout for the given period.
        func payOut(_ period: AllowancePeriod) async throws {
            appState.currentProfile = guildMaster
            try await treasury.runPayout(period: period)
        }
    }

    @Test
    func `real time settlement followed by week end payout does not double count the wallet`() async throws {
        let scaffold = try PayoutScaffold()
        scaffold.seedEarned()

        let settled = try await scaffold.settle()
        try await scaffold.payOut(settled)

        // The wallet must show the week's quest earnings exactly once — 25.0,
        // not 50.0. Before the fix the payout minted a second "payout-" entry
        // for the same amount, doubling the balance for real-time heroes.
        let balance = try await scaffold.treasury.currentBalance(for: scaffold.hero)
        #expect(balance == 25.0, "Week-end payout must not double-count real-time settlement")

        // The ledger holds only the real-time entry — no batch payout twin.
        let entries = scaffold.cache.fetchLedgerEntries(
            profileRecordName: scaffold.hero.id.recordName,
            family: scaffold.family.id.recordName
        )
        #expect(entries.count == 1, "Real-time period must have exactly one ledger entry")
        #expect(entries.first?.recordName == "rt-\(settled.id.recordName)")
    }

    @Test
    func `week end payout for batch heroes still mints a payout entry`() async throws {
        let scaffold = try PayoutScaffold(policy: .perQuest)
        scaffold.seedEarned()

        // No real-time settlement: the Guild Master creates the period and pays.
        let period = try await scaffold.treasury.getOrCreateAllowancePeriod(
            profile: scaffold.hero,
            weekOf: scaffold.weekOf,
            family: scaffold.family
        )
        try await scaffold.payOut(period)

        let balance = try await scaffold.treasury.currentBalance(for: scaffold.hero)
        #expect(balance == 25.0, "Batch payout mints the single payout entry")

        let entries = scaffold.cache.fetchLedgerEntries(
            profileRecordName: scaffold.hero.id.recordName,
            family: scaffold.family.id.recordName
        )
        #expect(entries.count == 1, "Batch period must mint exactly one ledger entry")
        #expect(entries.first?.recordName == "payout-\(period.id.recordName)")
    }

    @Test
    func `parent verified completion still settles real time gold`() async throws {
        let scaffold = try PayoutScaffold(policy: .realTime)
        scaffold.seedEarned()

        // A parent verifying the hero's quest settles on the hero's behalf:
        // the acting profile is the Guild Master, not the hero. Before the
        // self-or-parent guard this returned nil and the hero's wallet never
        // saw the gold.
        scaffold.appState.currentProfile = scaffold.guildMaster
        let settled = try await scaffold.treasury.processRealTimeSettlement(
            profile: scaffold.hero,
            family: scaffold.family,
            date: scaffold.weekOf
        )
        let period = try #require(settled, "Parent-verified settlement must not be dropped")

        #expect(period.totalEarned == 25.0, "Parent-verified quest gold must land on the period")
        #expect(period.questsCompleted == 1, "Parent-verified completion must count on the period")
        #expect(period.paidAmount == 25.0)
        #expect(period.status == .active, "Parent-verified settlement must not close the period")

        // The hero's wallet shows the settled gold and the ledger holds the
        // single real-time entry — settlement was NOT silently dropped.
        let balance = try await scaffold.treasury.currentBalance(for: scaffold.hero)
        #expect(balance == 25.0, "Parent-verified completion must credit the hero's wallet")

        let entries = scaffold.cache.fetchLedgerEntries(
            profileRecordName: scaffold.hero.id.recordName,
            family: scaffold.family.id.recordName
        )
        #expect(entries.count == 1, "Parent-verified settlement must mint exactly one ledger entry")
        #expect(entries.first?.recordName == "rt-\(period.id.recordName)")
        #expect(entries.first?.amount == 25.0)
    }
}
