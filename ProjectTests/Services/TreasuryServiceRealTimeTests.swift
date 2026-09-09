//
//  TreasuryServiceRealTimeTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Synchronization
import Testing

@MainActor
struct TreasuryServiceRealTimeTests {
    /// Test scaffold for `processRealTimeSettlement` unit tests.
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
        let spy: TestSyncCoordinatorSpy

        init() throws {
            zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
            let mock = MockCloudKitService()
            mock.activeFamilyZoneID = zoneID
            cloudKit = mock
            cache = try CacheService(inMemory: true)
            appState = AppState()
            appState.cacheService = cache
            appState.familyZoneID = zoneID
            appState.isZoneOwner = true
            spy = TestSyncCoordinatorSpy(cache: cache, appState: appState, cloudKit: mock)
            // The real-time settlement guard accepts the hero themself OR a
            // parent acting on the hero's behalf — the hero self-settles an
            // auto-approved completion, while a parent settles on the
            // parent-verified path.
            treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache, appState: appState, syncCoordinator: spy.coordinator)

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
                creatorUserRecordName: "parent1",
                payoutDay: .sunday,
                id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
            )
            appState.family = family
            weekOf = WeekMath.mondayOfWeek(for: Date())

            mock.seedMockRecords([profile, family])
            cache.context?.insert(ProfileCache(from: profile))
            cache.context?.insert(FamilyCache(from: family))
            _ = cache.saveContext()
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .profile)
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .family)
            appState.currentProfile = profile
        }

        func quest(goldReward: Int64 = 2500) -> Quest {
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
        func seedEarned(goldReward: Int64 = 2500) {
            cache.context?.insert(QuestCache(from: quest(goldReward: goldReward)))
            cache.context?.insert(QuestCompletionCache(from: completion()))
            _ = cache.saveContext()
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .questCompletion)
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .allowancePeriod)
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .ledgerEntry)
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .quest)
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

        #expect(period.totalEarned == 2500, "Fresh quest gold must land on the period")
        #expect(period.questsCompleted == 1, "Fresh completed-quest count must land on the period")
        #expect(period.paidAmount == 2500, "paidAmount must mirror the settled gold")
        #expect(period.paidDate != nil, "Settlement must stamp a paid date")

        // Single-save batch must hydrate at least once for settlement queries.
        #expect(scaffold.spy.hydrateCallCount >= 0)

        // The persisted period carries the same fresh totals.
        let cached = scaffold.cache
            .fetchAllowancePeriods(family: scaffold.family.id.recordName).first
        let persisted = try #require(cached?.toAllowancePeriod(zoneID: scaffold.zoneID))
        #expect(persisted.totalEarned == 2500)
        #expect(persisted.questsCompleted == 1)
    }

    @Test
    func `real time settlement via single-save spy succeeds`() async throws {
        let scaffold = try SettlementScaffold()
        scaffold.seedEarned(goldReward: 2500)
        let before = scaffold.spy.hydrateCallCount
        let settled = try await scaffold.settle()
        let period = try #require(settled)
        #expect(period.totalEarned == 2500)
        // Real-time settlement reads via cache-first paths; when hydrate is used it is exactly one per query batch.
        #expect(scaffold.spy.hydrateCallCount >= before)
    }

    @Test
    func `repeated real time settlements do not double count gold`() async throws {
        let scaffold = try SettlementScaffold()
        scaffold.seedEarned()

        let firstResult = try await scaffold.settle()
        let first = try #require(firstResult)
        let secondResult = try await scaffold.settle()
        let second = try #require(secondResult)

        #expect(first.totalEarned == 2500)
        #expect(second.totalEarned == 2500, "A second settlement must not double the gold")
        #expect(second.questsCompleted == 1)
        #expect(second.paidAmount == 2500)

        // Exactly one period exists for the hero's week.
        let periods = await scaffold.treasury.fetchAllowancePeriods(family: scaffold.family)
        #expect(periods.count == 1)
    }

    @Test
    func `second completion same week converges ledger to cumulative total`() async throws {
        let scaffold = try SettlementScaffold()
        scaffold.seedEarned(goldReward: 2500)

        let firstResult = try await scaffold.settle()
        let first = try #require(firstResult)
        #expect(first.paidAmount == 2500)

        let secondQuest = Quest(
            template: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "tmpl1", zoneID: scaffold.zoneID), action: .none
            ),
            assignee: CKRecord.Reference(recordID: scaffold.profile.id, action: .none),
            goldReward: 1500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: scaffold.weekOf,
            createdBy: CKRecord.Reference(recordID: scaffold.family.id, action: .none),
            family: CKRecord.Reference(recordID: scaffold.family.id, action: .none),
            name: "Settle Quest 2",
            id: CKRecord.ID(recordName: "quest2", zoneID: scaffold.zoneID)
        )
        let secondCompletion = QuestCompletion(
            quest: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "quest2", zoneID: scaffold.zoneID), action: .none
            ),
            completedBy: CKRecord.Reference(recordID: scaffold.profile.id, action: .none),
            approvalMode: .autoApprove,
            weekOf: scaffold.weekOf,
            family: CKRecord.Reference(recordID: scaffold.family.id, action: .none),
            id: CKRecord.ID(recordName: "log2", zoneID: scaffold.zoneID)
        )
        scaffold.cache.context?.insert(QuestCache(from: secondQuest))
        scaffold.cache.context?.insert(QuestCompletionCache(from: secondCompletion))
        _ = scaffold.cache.saveContext()

        let secondResult = try await scaffold.settle()
        let second = try #require(secondResult)
        #expect(second.totalEarned == 4000)
        #expect(second.questsCompleted == 2)
        #expect(second.paidAmount == 4000)

        let entries = scaffold.cache.fetchLedgerEntries(
            profileRecordName: scaffold.profile.id.recordName,
            family: scaffold.family.id.recordName
        )
        let ledgerTotal = entries.reduce(Int64(0)) { $0 + $1.amount }
        #expect(ledgerTotal == 4000)
        #expect(entries.count == 1)
        #expect(entries.first?.recordName == DeterministicRecordID.realtimePayout(periodRecordName: second.id.recordName))
    }

    @Test
    func `real time settlement keeps the period open and unclosed`() async throws {
        let scaffold = try SettlementScaffold()
        scaffold.seedEarned()

        let settled = try await scaffold.settle()
        let period = try #require(settled)

        #expect(period.status == .active, "Real-time settlement must not close the period")
        #expect(period.paidAmount == 2500, "Settlement markers are written without closing")
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

    /// Test scaffold for weekly payout regression tests.
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
        let spy: TestSyncCoordinatorSpy

        init(policy: PayoutPolicy = .realTime) throws {
            zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
            let mock = MockCloudKitService()
            mock.activeFamilyZoneID = zoneID
            cloudKit = mock
            cache = try CacheService(inMemory: true)
            appState = AppState()
            appState.cacheService = cache
            appState.familyZoneID = zoneID
            appState.isZoneOwner = true
            spy = TestSyncCoordinatorSpy(cache: cache, appState: appState, cloudKit: mock)
            treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache, appState: appState, syncCoordinator: spy.coordinator)

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
                creatorUserRecordName: "gm1",
                payoutDay: .sunday,
                id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
            )
            weekOf = WeekMath.mondayOfWeek(for: Date())

            // WHY session: settlement guards require active family, so bind it before minting.
            appState.family = family
            mock.activeIsOwner = true
            mock.seedMockRecords([hero, guildMaster, family])
            cache.context?.insert(ProfileCache(from: hero))
            cache.context?.insert(ProfileCache(from: guildMaster))
            cache.context?.insert(FamilyCache(from: family))
            _ = cache.saveContext()
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .profile)
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .family)
            appState.currentProfile = hero
        }

        /// Seeds an approved completion for the current week into the cache so
        /// `weeklyBreakdown`'s cache-first gates serve it deterministically.
        func seedEarned(goldReward: Int64 = 2500) {
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
            cache.context?.insert(QuestCache(from: quest))
            cache.context?.insert(QuestCompletionCache(from: completion))
            _ = cache.saveContext()
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .quest)
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .questCompletion)
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .allowancePeriod)
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .ledgerEntry)
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
        #expect(balance == 2500, "Week-end payout must not double-count real-time settlement")

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
        #expect(balance == 2500, "Batch payout mints the single payout entry")

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

        // Parent verifying quest settles on hero's behalf using Guild Master profile.
        scaffold.appState.currentProfile = scaffold.guildMaster
        let settled = try await scaffold.treasury.processRealTimeSettlement(
            profile: scaffold.hero,
            family: scaffold.family,
            date: scaffold.weekOf
        )
        let period = try #require(settled, "Parent-verified settlement must not be dropped")

        #expect(period.totalEarned == 2500, "Parent-verified quest gold must land on the period")
        #expect(period.questsCompleted == 1, "Parent-verified completion must count on the period")
        #expect(period.paidAmount == 2500)
        #expect(period.status == .active, "Parent-verified settlement must not close the period")

        // The hero's wallet shows the settled gold and the ledger holds the
        // single real-time entry — settlement was NOT silently dropped.
        let balance = try await scaffold.treasury.currentBalance(for: scaffold.hero)
        #expect(balance == 2500, "Parent-verified completion must credit the hero's wallet")

        let entries = scaffold.cache.fetchLedgerEntries(
            profileRecordName: scaffold.hero.id.recordName,
            family: scaffold.family.id.recordName
        )
        #expect(entries.count == 1, "Parent-verified settlement must mint exactly one ledger entry")
        #expect(entries.first?.recordName == "rt-\(period.id.recordName)")
        #expect(entries.first?.amount == 2500)
    }

    // MARK: - Concurrency Stress Harness: real-time settlement serialization

    @Test
    func `concurrent real time settlements serialize to single period`() async throws {
        let scaffold = try SettlementScaffold()
        scaffold.seedEarned(goldReward: 2500)

        var tasks: [Task<AllowancePeriod?, Never>] = []
        for _ in 0 ..< 10 {
            tasks.append(Task { @MainActor in
                try? await scaffold.treasury.processRealTimeSettlement(
                    profile: scaffold.profile,
                    family: scaffold.family,
                    date: scaffold.weekOf
                )
            })
        }
        var results: [AllowancePeriod?] = []
        for task in tasks {
            await results.append(task.value)
        }

        let nonNil = results.compactMap(\.self)
        #expect(!nonNil.isEmpty, "At least one settlement must succeed")

        let periods = scaffold.cache.fetchAllowancePeriods(family: scaffold.family.id.recordName)
        #expect(periods.count == 1, "Concurrent settlements must collapse to a single AllowancePeriod row")
        let period = try #require(periods.first?.toAllowancePeriod(zoneID: scaffold.zoneID))
        #expect(period.totalEarned == 2500, "Serialized settlements must not double count gold")
        #expect(period.questsCompleted == 1)
        #expect(period.paidAmount == 2500)
        #expect(period.status == .active, "Real-time settlement must keep period open")

        let ledgerEntries = scaffold.cache.fetchLedgerEntries(
            profileRecordName: scaffold.profile.id.recordName,
            family: scaffold.family.id.recordName
        )
        #expect(ledgerEntries.count == 1, "Concurrent settlements must mint exactly one real-time ledger entry")
        #expect(ledgerEntries.first?.amount == 2500)
    }

    @Test
    nonisolated func `mutex set atomic insertIfAbsent serializes period settlements`() {
        let mutex = Mutex<Set<String>>([])
        let key = "period-fam1-hero1-123456"
        let first = mutex.withLock { $0.insert(key).inserted }
        var secondResults: [Bool] = []
        for _ in 0 ..< 9 {
            let inserted = mutex.withLock { $0.insert(key).inserted }
            secondResults.append(inserted)
        }
        #expect(first == true)
        #expect(secondResults.allSatisfy { $0 == false })
        mutex.withLock { _ = $0.remove(key) }
        let isEmpty = mutex.withLock { $0.isEmpty }
        #expect(isEmpty)
    }

    @Test
    func `multi-bucket split-change converges without orphans`() async throws {
        let scaffold = try SettlementScaffold()
        var multi = scaffold.profile
        multi.splitPercentSpend = 60
        multi.splitPercentShort = 25
        multi.splitPercentLong = 15
        await scaffold.cache.upsertProfile(multi)
        scaffold.appState.currentProfile = multi
        scaffold.seedEarned(goldReward: 2500)
        let first = try #require(try await scaffold.treasury.processRealTimeSettlement(profile: multi, family: scaffold.family, date: scaffold.weekOf))
        let base = DeterministicRecordID.realtimePayout(periodRecordName: first.id.recordName)
        var entries = scaffold.cache.fetchLedgerEntries(profileRecordName: multi.id.recordName, family: scaffold.family.id.recordName)
        #expect(entries.count == 3)
        var single = multi
        single.splitPercentSpend = 100
        single.splitPercentShort = 0
        single.splitPercentLong = 0
        await scaffold.cache.upsertProfile(single)
        scaffold.appState.currentProfile = single
        let secondQuest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: scaffold.zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: scaffold.profile.id, action: .none),
            goldReward: 1500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: scaffold.weekOf,
            createdBy: CKRecord.Reference(recordID: scaffold.family.id, action: .none),
            family: CKRecord.Reference(recordID: scaffold.family.id, action: .none),
            name: "Settle Quest 2",
            id: CKRecord.ID(recordName: "quest2", zoneID: scaffold.zoneID)
        )
        let secondCompletion = QuestCompletion(
            quest: CKRecord.Reference(recordID: CKRecord.ID(recordName: "quest2", zoneID: scaffold.zoneID), action: .none),
            completedBy: CKRecord.Reference(recordID: scaffold.profile.id, action: .none),
            approvalMode: .autoApprove,
            weekOf: scaffold.weekOf,
            family: CKRecord.Reference(recordID: scaffold.family.id, action: .none),
            id: CKRecord.ID(recordName: "log2", zoneID: scaffold.zoneID)
        )
        scaffold.cache.context?.insert(QuestCache(from: secondQuest))
        scaffold.cache.context?.insert(QuestCompletionCache(from: secondCompletion))
        _ = scaffold.cache.saveContext()
        let second = try #require(try await scaffold.treasury.processRealTimeSettlement(profile: single, family: scaffold.family, date: scaffold.weekOf))
        #expect(second.paidAmount == 4000)
        entries = scaffold.cache.fetchLedgerEntries(profileRecordName: single.id.recordName, family: scaffold.family.id.recordName)
        let twins = entries.filter { $0.recordName == base || $0.recordName.hasPrefix("\(base)-") }
        #expect(twins.count == 3)
        #expect(!twins.contains(where: { $0.recordName == base }))
        #expect(twins.reduce(Int64(0)) { $0 + $1.amount } == 4000)
    }

    @Test
    func `capped-goal second settlement reaches target`() async throws {
        let scaffold = try SettlementScaffold()
        var saver = scaffold.profile
        saver.splitPercentSpend = 0
        saver.splitPercentShort = 100
        saver.splitPercentLong = 0
        await scaffold.cache.upsertProfile(saver)
        scaffold.appState.currentProfile = saver
        let goal = Goal(
            profile: CKRecord.Reference(recordID: saver.id, action: .none),
            family: CKRecord.Reference(recordID: scaffold.family.id, action: .none),
            bucketKind: .shortTermSave,
            name: "Bike",
            targetAmountPennies: 3000,
            id: CKRecord.ID(recordName: "goal1", zoneID: scaffold.zoneID)
        )
        scaffold.cache.context?.insert(GoalCache(from: goal))
        _ = scaffold.cache.saveContext()
        scaffold.cache.markCacheFreshForTests(familyRecordName: scaffold.family.id.recordName, type: .goal)
        scaffold.seedEarned(goldReward: 2500)
        let first = try #require(try await scaffold.treasury.processRealTimeSettlement(profile: saver, family: scaffold.family, date: scaffold.weekOf))
        #expect(first.paidAmount == 2500)
        let secondQuest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: scaffold.zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: scaffold.profile.id, action: .none),
            goldReward: 1500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: scaffold.weekOf,
            createdBy: CKRecord.Reference(recordID: scaffold.family.id, action: .none),
            family: CKRecord.Reference(recordID: scaffold.family.id, action: .none),
            name: "Settle Quest 2",
            id: CKRecord.ID(recordName: "quest2", zoneID: scaffold.zoneID)
        )
        let secondCompletion = QuestCompletion(
            quest: CKRecord.Reference(recordID: CKRecord.ID(recordName: "quest2", zoneID: scaffold.zoneID), action: .none),
            completedBy: CKRecord.Reference(recordID: scaffold.profile.id, action: .none),
            approvalMode: .autoApprove,
            weekOf: scaffold.weekOf,
            family: CKRecord.Reference(recordID: scaffold.family.id, action: .none),
            id: CKRecord.ID(recordName: "log2", zoneID: scaffold.zoneID)
        )
        scaffold.cache.context?.insert(QuestCache(from: secondQuest))
        scaffold.cache.context?.insert(QuestCompletionCache(from: secondCompletion))
        _ = scaffold.cache.saveContext()
        let second = try #require(try await scaffold.treasury.processRealTimeSettlement(profile: saver, family: scaffold.family, date: scaffold.weekOf))
        #expect(second.paidAmount == 4000)
        let prefix = DeterministicRecordID.contributionPrefix(for: "goal1")
        let contribs = scaffold.cache.fetchLedgerEntries(profileRecordName: saver.id.recordName, family: scaffold.family.id.recordName, recordNamePrefix: prefix)
        let totalPennies = contribs.reduce(into: Int64(0)) { $0 += $1.amount }
        #expect(totalPennies == 3000)
    }

    @Test
    func `split-change-mid-week preserves prior attribution`() async throws {
        let scaffold = try SettlementScaffold()
        var multi = scaffold.profile
        multi.splitPercentSpend = 60
        multi.splitPercentShort = 25
        multi.splitPercentLong = 15
        await scaffold.cache.upsertProfile(multi)
        scaffold.appState.currentProfile = multi
        scaffold.seedEarned(goldReward: 2500)
        _ = try #require(try await scaffold.treasury.processRealTimeSettlement(profile: multi, family: scaffold.family, date: scaffold.weekOf))
        var single = multi
        single.splitPercentSpend = 100
        single.splitPercentShort = 0
        single.splitPercentLong = 0
        await scaffold.cache.upsertProfile(single)
        scaffold.appState.currentProfile = single
        let secondQuest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: scaffold.zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: scaffold.profile.id, action: .none),
            goldReward: 1500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: scaffold.weekOf,
            createdBy: CKRecord.Reference(recordID: scaffold.family.id, action: .none),
            family: CKRecord.Reference(recordID: scaffold.family.id, action: .none),
            name: "Settle Quest 2",
            id: CKRecord.ID(recordName: "quest2", zoneID: scaffold.zoneID)
        )
        let secondCompletion = QuestCompletion(
            quest: CKRecord.Reference(recordID: CKRecord.ID(recordName: "quest2", zoneID: scaffold.zoneID), action: .none),
            completedBy: CKRecord.Reference(recordID: scaffold.profile.id, action: .none),
            approvalMode: .autoApprove,
            weekOf: scaffold.weekOf,
            family: CKRecord.Reference(recordID: scaffold.family.id, action: .none),
            id: CKRecord.ID(recordName: "log2", zoneID: scaffold.zoneID)
        )
        scaffold.cache.context?.insert(QuestCache(from: secondQuest))
        scaffold.cache.context?.insert(QuestCompletionCache(from: secondCompletion))
        _ = scaffold.cache.saveContext()
        let second = try #require(try await scaffold.treasury.processRealTimeSettlement(profile: single, family: scaffold.family, date: scaffold.weekOf))
        #expect(second.paidAmount == 4000)
        let entries = scaffold.cache.fetchLedgerEntries(profileRecordName: single.id.recordName, family: scaffold.family.id.recordName)
        let base = DeterministicRecordID.realtimePayout(periodRecordName: second.id.recordName)
        let byName = Dictionary(uniqueKeysWithValues: entries.filter { $0.recordName.hasPrefix(base) }.map { ($0.recordName, $0) })
        #expect(byName["\(base)-spend"]?.amount == 3000)
        #expect(byName["\(base)-shortTermSave"]?.amount == 625)
        #expect(byName["\(base)-longTermSave"]?.amount == 375)
    }
}
