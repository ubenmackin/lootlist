//
//  OptimisticRollbackTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
import Foundation
@testable import LootList
import XCTest

@MainActor
final class OptimisticRollbackTests: XCTestCase {
    var appState: AppState!
    var cloudKit: MockCloudKitService!
    var cacheService: CacheService!
    var questService: QuestService!
    var xpService: XPService!
    var family: Family!
    var hero: Profile!
    var zoneID: CKRecordZone.ID!

    override func setUp() async throws {
        try await super.setUp()
        zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        cacheService = try CacheService(inMemory: true)
        appState = AppState()
        appState.cacheService = cacheService

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let userID = CKRecord.ID(recordName: "user1", zoneID: zoneID)

        hero = Profile(
            displayName: "Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: userID,
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )

        family = Family(
            name: "Test Guild",
            createdBy: hero.id,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        appState.family = family
        appState.currentProfile = hero
        appState.familyZoneID = zoneID
        appState.isZoneOwner = cloudKit.activeIsOwner

        xpService = XPService(cloudKit: cloudKit, cacheService: cacheService, appState: appState)
        questService = QuestService(
            cloudKit: cloudKit,
            xpService: xpService,
            cacheService: cacheService,
            appState: appState
        )
    }

    func testDeterministicRewardEventRecordID() {
        let completionName = "completion-123"
        let expectedID = CKRecord.ID(recordName: "reward-completion-123", zoneID: zoneID)
        let actualID = RewardEvent.recordID(completionRecordName: completionName, zoneID: zoneID)

        XCTAssertEqual(actualID, expectedID)
    }

    func testReRunningRewardGrantWithExistingCreditDoesNotMintDuplicateXP() async throws {
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let heroRef = CKRecord.Reference(recordID: hero.id, action: .none)
        let templateRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "t1", zoneID: zoneID), action: .none)
        let weekStart = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)

        let quest = Quest(
            template: templateRef,
            assignee: heroRef,
            goldReward: 10,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekStart,
            createdBy: heroRef,
            family: familyRef,
            name: "Daily Workout",
            descriptionText: "Do pushups",
            id: CKRecord.ID(recordName: "q1", zoneID: zoneID)
        )

        // Seed initial records
        cacheService.upsertProfile(hero)
        cacheService.upsertQuest(quest)
        cloudKit.seedMockRecords([hero, quest])

        // 1. A completion that already has xpCredited stamped
        let alreadyCreditedCompletion = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: heroRef,
            approvalMode: .autoApprove,
            completedDate: Date(),
            weekOf: weekStart,
            family: familyRef,
            xpCredited: 50,
            id: CKRecord.ID(recordName: "c1", zoneID: zoneID)
        )

        let initialXP = hero.xp
        _ = try await questService.applyReward(for: quest, to: hero, completion: alreadyCreditedCompletion)

        let heroAfterSkippedCredit = cacheService.fetchProfile(recordName: hero.id.recordName, family: family.id.recordName)
        XCTAssertEqual(heroAfterSkippedCredit?.xpTotal, initialXP, "Already credited completion should not grant duplicate XP")

        // 2. A fresh completion with nil xpCredited
        let freshCompletion = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: heroRef,
            approvalMode: .autoApprove,
            completedDate: Date(),
            weekOf: weekStart,
            family: familyRef,
            xpCredited: nil,
            id: CKRecord.ID(recordName: "c2", zoneID: zoneID)
        )

        _ = try await questService.applyReward(for: quest, to: hero, completion: freshCompletion)

        let heroAfterFreshCredit = cacheService.fetchProfile(recordName: hero.id.recordName, family: family.id.recordName)
        XCTAssertEqual(heroAfterFreshCredit?.xpTotal, initialXP + 50, "Fresh completion should grant XP reward")
    }

    func testDeterministicPayoutLedgerEntryMintingAndDoubleMintPrevention() async throws {
        let parentID = CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        let parent = Profile(
            displayName: "Guild Master",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: parentID,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: parentID
        )
        appState.currentProfile = parent
        cacheService.upsertProfile(parent)
        cacheService.upsertProfile(hero)
        cacheService.upsertFamily(family)
        cloudKit.seedMockRecords([parent, hero, family])

        let treasuryService = TreasuryService(
            cloudKit: cloudKit,
            cacheService: cacheService,
            appState: appState
        )

        let weekStart = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "t1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 25.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekStart,
            createdBy: CKRecord.Reference(recordID: parent.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: "Dragon Slaying",
            id: CKRecord.ID(recordName: "q_payout", zoneID: zoneID)
        )
        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
            approvalMode: .autoApprove,
            completedDate: weekStart.addingTimeInterval(3600),
            weekOf: weekStart,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "c_payout", zoneID: zoneID)
        )
        cacheService.upsertQuest(quest)
        cacheService.upsertQuestCompletion(completion)
        cloudKit.seedMockRecords([quest, completion])

        let periodRecordName = "period-\(family.id.recordName)-\(hero.id.recordName)-\(Int(weekStart.timeIntervalSince1970))"
        let period = AllowancePeriod(
            weekOf: weekStart,
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            questsTotal: 1,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: periodRecordName, zoneID: zoneID)
        )
        var unfinalized = period
        unfinalized.status = .active
        unfinalized.totalEarned = 25.0
        unfinalized.questsCompleted = 1
        cacheService.upsertAllowancePeriod(unfinalized)
        cloudKit.seedMockRecords([unfinalized])

        // First payout run: mints the deterministic payout ledger entry
        try await treasuryService.runPayout(period: unfinalized)

        let paidPeriod = cacheService.fetchAllowancePeriod(recordName: periodRecordName, family: family.id.recordName)
        XCTAssertEqual(paidPeriod?.statusEnum, .paid)
        XCTAssertEqual(paidPeriod?.paidAmount, 25.0)

        let expectedLedgerName = "payout-\(periodRecordName)"
        let ledgersAfterFirst = cacheService.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        XCTAssertEqual(ledgersAfterFirst.count, 1)
        XCTAssertEqual(ledgersAfterFirst.first?.recordName, expectedLedgerName)
        XCTAssertEqual(ledgersAfterFirst.first?.amount, 25.0)

        // Second payout run (e.g. cross-device race or replay): double-mint guard must prevent duplicate ledger creation
        if let paidPeriodDomain = paidPeriod?.toAllowancePeriod(zoneID: zoneID) {
            try await treasuryService.runPayout(period: paidPeriodDomain)
        }

        let ledgersAfterSecond = cacheService.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        XCTAssertEqual(ledgersAfterSecond.count, 1, "Double-mint guard must prevent duplicate ledger entries on re-run")
    }

    func testPayoutSkipsMintingWhenRealTimeLedgerAlreadyExists() async throws {
        let parentID = CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        let parent = Profile(
            displayName: "Guild Master",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: parentID,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: parentID
        )
        appState.currentProfile = parent
        cacheService.upsertProfile(parent)
        cacheService.upsertProfile(hero)
        cacheService.upsertFamily(family)
        cloudKit.seedMockRecords([parent, hero, family])

        let treasuryService = TreasuryService(
            cloudKit: cloudKit,
            cacheService: cacheService,
            appState: appState
        )

        let weekStart = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "t1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 15.0,
            xpReward: 30,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekStart,
            createdBy: CKRecord.Reference(recordID: parent.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: "Sweep Floor",
            id: CKRecord.ID(recordName: "q_rt", zoneID: zoneID)
        )
        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
            approvalMode: .autoApprove,
            completedDate: weekStart.addingTimeInterval(3600),
            weekOf: weekStart,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "c_rt", zoneID: zoneID)
        )
        cacheService.upsertQuest(quest)
        cacheService.upsertQuestCompletion(completion)
        cloudKit.seedMockRecords([quest, completion])

        let periodRecordName = "period-\(family.id.recordName)-\(hero.id.recordName)-\(Int(weekStart.timeIntervalSince1970))"

        // Seed a pre-existing real-time ledger entry for this period
        let rtLedger = LedgerEntry(
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            amount: 15.0,
            description: "Real-time quest earnings",
            date: Date(),
            source: "quest",
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "rt-\(periodRecordName)", zoneID: zoneID)
        )
        cacheService.upsertLedgerEntry(rtLedger)

        let period = AllowancePeriod(
            weekOf: weekStart,
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            questsTotal: 1,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: periodRecordName, zoneID: zoneID)
        )
        var unfinalized = period
        unfinalized.status = .active
        unfinalized.totalEarned = 15.0
        unfinalized.questsCompleted = 1
        cacheService.upsertAllowancePeriod(unfinalized)

        try await treasuryService.runPayout(period: unfinalized)

        let allLedgers = cacheService.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        XCTAssertEqual(allLedgers.count, 1, "Defense-in-depth: rt- ledger prevents payout- double minting")
        XCTAssertEqual(allLedgers.first?.recordName, "rt-\(periodRecordName)")
    }

    func testSaveErrorInjectionThrowsAndDoesNotPersistStaleCloudRecord() async throws {
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let heroRef = CKRecord.Reference(recordID: hero.id, action: .none)
        let templateRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "t1", zoneID: zoneID), action: .none)
        let weekStart = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)

        let quest = Quest(
            template: templateRef,
            assignee: heroRef,
            goldReward: 10,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekStart,
            createdBy: heroRef,
            family: familyRef,
            name: "Daily Workout",
            descriptionText: "Do pushups",
            id: CKRecord.ID(recordName: "q1", zoneID: zoneID)
        )

        cloudKit.seedMockRecords([hero, quest])
        cloudKit.saveError = CloudKitServiceError.serverRecordChanged

        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: heroRef,
            approvalMode: .autoApprove,
            completedDate: Date(),
            weekOf: weekStart,
            family: familyRef,
            xpCredited: nil,
            id: CKRecord.ID(recordName: "c3", zoneID: zoneID)
        )

        do {
            _ = try await questService.applyReward(for: quest, to: hero, completion: completion)
        } catch {
            XCTAssertTrue(error is CloudKitServiceError)
        }
    }

    func testDeterministicRecordNamesAreStableAndZoneIndependent() {
        let zoneA = CKRecordZone.ID(zoneName: "ZoneA", ownerName: "OwnerA")
        let zoneB = CKRecordZone.ID(zoneName: "ZoneB", ownerName: "OwnerB")
        let periodName = "period-fam1-hero1-1234567890"

        let payoutA = CKRecord.ID(recordName: "payout-\(periodName)", zoneID: zoneA)
        let payoutB = CKRecord.ID(recordName: "payout-\(periodName)", zoneID: zoneB)
        XCTAssertEqual(payoutA.recordName, payoutB.recordName)
        XCTAssertEqual(payoutA.recordName, "payout-period-fam1-hero1-1234567890")

        let rtA = CKRecord.ID(recordName: "rt-\(periodName)", zoneID: zoneA)
        let rtB = CKRecord.ID(recordName: "rt-\(periodName)", zoneID: zoneB)
        XCTAssertEqual(rtA.recordName, rtB.recordName)
        XCTAssertEqual(rtA.recordName, "rt-period-fam1-hero1-1234567890")
        XCTAssertNotEqual(payoutA.recordName, rtA.recordName)

        let rewardA = RewardEvent.recordID(completionRecordName: "completion-xyz", zoneID: zoneA)
        let rewardB = RewardEvent.recordID(completionRecordName: "completion-xyz", zoneID: zoneB)
        XCTAssertEqual(rewardA.recordName, rewardB.recordName)
        XCTAssertEqual(rewardA.recordName, "reward-completion-xyz")

        let gemA = GemLedger.deterministicRecordID(
            profileRecordName: "hero1",
            eventKey: "event-abc",
            source: "dailyLogin",
            zoneID: zoneA
        )
        let gemB = GemLedger.deterministicRecordID(
            profileRecordName: "hero1",
            eventKey: "event-abc",
            source: "dailyLogin",
            zoneID: zoneB
        )
        XCTAssertEqual(gemA.recordName, gemB.recordName)
        XCTAssertEqual(gemA.recordName, "gem-hero1-event-abc-dailyLogin")

        let purchaseA = GemLedger.purchaseRecordID(
            profileRecordName: "hero1",
            itemID: "headwear_golden_crown",
            eventKey: nil,
            zoneID: zoneA
        )
        let purchaseB = GemLedger.purchaseRecordID(
            profileRecordName: "hero1",
            itemID: "headwear_golden_crown",
            eventKey: nil,
            zoneID: zoneB
        )
        XCTAssertEqual(purchaseA.recordName, purchaseB.recordName)
        XCTAssertEqual(purchaseA.recordName, "gem-hero1-purchase-headwear_golden_crown-shopPurchase")
    }

    func testConcurrentDuplicateGemLedgerDoesNotDoubleMint() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "ConcZone", ownerName: "Owner")
        let mock = MockCloudKitService()
        mock.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let state = AppState()
        state.cacheService = cache
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let localHero = Profile(
            displayName: "Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            id: heroID
        )
        let testFamily = Family(name: "Guild", createdBy: heroID, id: CKRecord.ID(recordName: "fam1", zoneID: zoneID))
        cache.upsertFamily(testFamily)
        cache.upsertProfile(localHero)
        mock.seedMockRecords([testFamily, localHero])
        state.family = testFamily
        state.familyZoneID = zoneID
        state.currentProfile = localHero
        state.isZoneOwner = true

        let gemService = GemService(cloudKitService: mock, cacheService: cache, appState: state)
        let eventKey = "conc-event-001"

        var tasks: [Task<Void, Never>] = []
        for _ in 0 ..< 10 {
            tasks.append(Task { @MainActor in
                _ = try? await gemService.creditGems(amount: 15, to: localHero, source: "concurrentTest", eventKey: eventKey)
            })
        }
        for task in tasks {
            _ = await task.value
        }

        let ledgers = cache.fetchGemLedgers(family: "fam1")
        XCTAssertEqual(ledgers.count, 1, "Concurrent duplicate eventKey must produce exactly one ledger row")
        let balance = try gemService.balance(for: heroID.recordName, familyRecordName: "fam1")
        XCTAssertEqual(balance, 15, "Concurrent duplicate must credit gems exactly once")
    }

    func testGemLedgerAndProfileBatchDoesNotLeavePartialOnSimulatedFailure() throws {
        let cache = try CacheService(inMemory: true)
        let failZone = CKRecordZone.ID(zoneName: "AtomicFailZone", ownerName: "Owner")
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: failZone), action: .none)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: failZone)
        var hero = Profile(
            displayName: "Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            id: heroID
        )
        hero.gems = 50
        cache.upsertProfile(hero)

        let ledger = GemLedger(
            profileRecordName: heroID.recordName,
            family: familyRef,
            amount: 25,
            source: "testReward",
            createdAt: Date(),
            id: GemLedger.deterministicRecordID(profileRecordName: heroID.recordName, eventKey: "atomic-fail", source: "testReward", zoneID: failZone)
        )
        var updated = hero
        updated.gems = 75

        cache.withBatch {
            cache.upsertProfile(updated)
            cache.upsertGemLedger(ledger)
            cache.context?.rollback()
        }

        XCTAssertEqual(cache.fetchGemLedgers(family: "fam1").count, 0, "Simulated batch failure must not leave a ledger row")
        XCTAssertEqual(cache.fetchProfile(recordName: heroID.recordName, family: "fam1")?.gemsTotal, 50, "Profile must remain at pre-batch value when batch fails")
    }

    func testLootDropRollAndCreditRespectsIdempotency() async throws {
        let lootZone = CKRecordZone.ID(zoneName: "LootZone", ownerName: "Owner")
        let mock = MockCloudKitService()
        mock.activeFamilyZoneID = lootZone
        let cache = try CacheService(inMemory: true)
        let state = AppState()
        state.cacheService = cache
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: lootZone), action: .none)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: lootZone)
        let hero = Profile(
            displayName: "Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            id: heroID
        )
        let family = Family(name: "Guild", createdBy: heroID, id: CKRecord.ID(recordName: "fam1", zoneID: lootZone))
        cache.upsertFamily(family)
        cache.upsertProfile(hero)
        mock.seedMockRecords([family, hero])
        state.family = family
        state.familyZoneID = lootZone
        state.currentProfile = hero

        let gemService = GemService(cloudKitService: mock, cacheService: cache, appState: state)

        let drop = LootDrop(gemAmount: 30, description: "Medium Gem Pouch", rarity: .epic)
        let lootService = LootDropService(gemService: gemService)
        lootService.rollProvider = { _, _ in drop }
        let eventKey = "loot-event-1"

        let first = await lootService.rollAndCredit(questRarity: .epic, streakDays: 5, to: hero, eventKey: eventKey)
        XCTAssertEqual(first, drop)
        let second = await lootService.rollAndCredit(questRarity: .epic, streakDays: 5, to: hero, eventKey: eventKey)
        XCTAssertNil(second)

        XCTAssertEqual(cache.fetchGemLedgers(family: "fam1").count, 1, "Second rollAndCredit with same eventKey must not double-mint")
        let balance = try gemService.balance(for: heroID.recordName, familyRecordName: "fam1")
        XCTAssertEqual(balance, 30)
    }

    func testRewardEventLoserPhantomCleanupAfterClaimFalse() async throws {
        let phantomZone = CKRecordZone.ID(zoneName: "PhantomZone", ownerName: "Owner")
        let mock = MockCloudKitService()
        mock.activeFamilyZoneID = phantomZone
        let cache = try CacheService(inMemory: true)
        let state = AppState()
        state.cacheService = cache

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: phantomZone), action: .none)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: phantomZone)
        let hero = Profile(
            displayName: "Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            id: heroID
        )
        let family = Family(name: "Guild", createdBy: heroID, id: CKRecord.ID(recordName: "fam1", zoneID: phantomZone))
        cache.upsertFamily(family)
        cache.upsertProfile(hero)
        mock.seedMockRecords([family, hero])
        state.family = family
        state.familyZoneID = phantomZone
        state.currentProfile = hero
        state.isZoneOwner = true

        let completionID = CKRecord.ID(recordName: "completion-loser", zoneID: phantomZone)
        let rewardID = RewardEvent.recordID(completionRecordName: completionID.recordName, zoneID: phantomZone)
        let existing = RewardEvent(
            profile: CKRecord.Reference(recordID: heroID, action: .none),
            questCompletion: CKRecord.Reference(recordID: completionID, action: .none),
            xpAmount: 50,
            goldAmount: 10,
            timestamp: Date(),
            family: familyRef,
            id: rewardID
        )
        mock.seedMockRecords([existing])

        let xpSvc = XPService(cloudKit: mock, cacheService: cache, appState: state)
        let qSvc = QuestService(cloudKit: mock, xpService: xpSvc, cacheService: cache, appState: state)
        let resolver = CKSyncConflictResolver(cacheService: cache, appState: state)
        let delegate = CKSyncEngineDelegateHandler(conflictResolver: resolver, cacheService: cache, appState: state)
        let coordinator = CKSyncEngineCoordinator(cloudKitService: mock, delegateHandler: delegate, appState: state)
        qSvc.syncCoordinator = coordinator
        coordinator.privateSyncEngine = CKSyncEngine(CKSyncEngine.Configuration(database: mock.container.privateCloudDatabase, stateSerialization: nil, delegate: delegate))

        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: phantomZone), action: .none),
            assignee: CKRecord.Reference(recordID: heroID, action: .none),
            goldReward: 10,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: CKRecord.Reference(recordID: heroID, action: .none),
            family: familyRef,
            name: "Loser Quest",
            id: CKRecord.ID(recordName: "q-loser", zoneID: phantomZone)
        )
        cache.upsertQuest(quest)
        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: CKRecord.Reference(recordID: heroID, action: .none),
            approvalMode: .autoApprove,
            completedDate: Date(),
            weekOf: quest.weekOf,
            family: familyRef,
            xpCredited: nil,
            id: completionID
        )

        let credited = try await qSvc.applyReward(for: quest, to: hero, completion: completion)
        XCTAssertEqual(credited, 0, "Loser must receive zero credit when claim returns false")

        let phantom = cache.fetchRewardEvent(recordName: rewardID.recordName, family: "fam1")
        XCTAssertNil(phantom, "Loser must not leave a local RewardEvent row after claim==false")
        XCTAssertEqual(coordinator.pendingUploadCount, 0, "Loser must not enqueue the phantom RewardEvent")

        let loserCompletion = cache.fetchQuestCompletion(recordName: completionID.recordName, family: "fam1")
        XCTAssertNil(loserCompletion?.xpCredited, "Loser completion must not be stamped")
    }

    func testSyncCoordinatorEnqueueNotCalledWhenRewardClaimLoses() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "NoEnqueueZone", ownerName: "Owner")
        let mock = MockCloudKitService()
        mock.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let state = AppState()
        state.cacheService = cache
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let hero = Profile(displayName: "Hero", avatarClass: .mage, avatarPresetID: "mage_01", role: .hero, iCloudUserID: heroID, family: familyRef, id: heroID)
        let family = Family(name: "Guild", createdBy: heroID, id: CKRecord.ID(recordName: "fam1", zoneID: zoneID))
        cache.upsertFamily(family)
        cache.upsertProfile(hero)
        mock.seedMockRecords([family, hero])
        state.family = family
        state.familyZoneID = zoneID
        state.currentProfile = hero

        let completionID = CKRecord.ID(recordName: "completion-no-enqueue", zoneID: zoneID)
        let rewardID = RewardEvent.recordID(completionRecordName: completionID.recordName, zoneID: zoneID)
        let preExisting = RewardEvent(
            profile: CKRecord.Reference(recordID: heroID, action: .none),
            questCompletion: CKRecord.Reference(recordID: completionID, action: .none),
            xpAmount: 20,
            goldAmount: 5,
            timestamp: Date(),
            family: familyRef,
            id: rewardID
        )
        mock.seedMockRecords([preExisting])

        let claimed = try await mock.claimRewardEvent(preExisting, in: zoneID, using: nil)
        XCTAssertFalse(claimed, "Pre-seeded reward must cause claim to return false for loser")

        let rewardCountBefore = cache.fetchRewardEvents(family: "fam1").count
        XCTAssertEqual(rewardCountBefore, 0, "Cache must have no reward before loser attempt")
    }
}
