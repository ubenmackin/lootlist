//
//  GemServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/19/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct GemServiceTests {
    private func makeZoneID(name: String = "TestZone") -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: name, ownerName: "TestOwner")
    }

    private func makeProfile(zoneID: CKRecordZone.ID, recordName: String = "hero1") -> Profile {
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let profileID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        return Profile(
            displayName: "Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: profileID,
            family: familyRef,
            id: profileID
        )
    }

    private func makeFamily(zoneID: CKRecordZone.ID) -> Family {
        Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "hero1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
    }

    // MARK: - Deterministic recordName generation

    @Test
    func `deterministic gem ledger recordName is stable and zone independent`() {
        let zoneA = CKRecordZone.ID(zoneName: "ZoneA", ownerName: "OwnerA")
        let zoneB = CKRecordZone.ID(zoneName: "ZoneB", ownerName: "OwnerB")
        let first = GemLedger.deterministicRecordID(
            profileRecordName: "hero-1",
            eventKey: "purchase-item-1",
            source: "shopPurchase",
            zoneID: zoneA
        )
        let retry = GemLedger.deterministicRecordID(
            profileRecordName: "hero-1",
            eventKey: "purchase-item-1",
            source: "shopPurchase",
            zoneID: zoneA
        )
        let crossZone = GemLedger.deterministicRecordID(
            profileRecordName: "hero-1",
            eventKey: "purchase-item-1",
            source: "shopPurchase",
            zoneID: zoneB
        )
        #expect(first.recordName == retry.recordName)
        #expect(first.recordName == crossZone.recordName)
        #expect(first.recordName == "gem-hero-1-purchase-item-1-shopPurchase")

        let differentEvent = GemLedger.deterministicRecordID(
            profileRecordName: "hero-1",
            eventKey: "purchase-item-2",
            source: "shopPurchase",
            zoneID: zoneA
        )
        #expect(first.recordName != differentEvent.recordName)
    }

    @Test
    func `purchaseRecordID is stable and zone independent`() {
        let zoneA = CKRecordZone.ID(zoneName: "ZoneA", ownerName: "OwnerA")
        let zoneB = CKRecordZone.ID(zoneName: "ZoneB", ownerName: "OwnerB")
        let fallbackA = GemLedger.purchaseRecordID(
            profileRecordName: "hero-1",
            itemID: "headwear_golden_crown",
            eventKey: nil,
            zoneID: zoneA
        )
        let fallbackB = GemLedger.purchaseRecordID(
            profileRecordName: "hero-1",
            itemID: "headwear_golden_crown",
            eventKey: nil,
            zoneID: zoneB
        )
        #expect(fallbackA.recordName == fallbackB.recordName)
        #expect(fallbackA.recordName == "gem-hero-1-purchase-headwear_golden_crown-shopPurchase")

        let explicitA = GemLedger.purchaseRecordID(
            profileRecordName: "hero-1",
            itemID: "headwear_golden_crown",
            eventKey: "shopPurchase-headwear_golden_crown",
            zoneID: zoneA
        )
        let explicitB = GemLedger.purchaseRecordID(
            profileRecordName: "hero-1",
            itemID: "headwear_golden_crown",
            eventKey: "shopPurchase-headwear_golden_crown",
            zoneID: zoneB
        )
        #expect(explicitA.recordName == explicitB.recordName)
        #expect(explicitA.recordName == "gem-hero-1-shopPurchase-headwear_golden_crown-shopPurchase")
    }

    @Test
    func `reward event recordName is stable and zone independent`() {
        let zoneA = CKRecordZone.ID(zoneName: "ZoneA", ownerName: "OwnerA")
        let zoneB = CKRecordZone.ID(zoneName: "ZoneB", ownerName: "OwnerB")
        let completionName = "completion-123"
        let idA = RewardEvent.recordID(completionRecordName: completionName, zoneID: zoneA)
        let idA2 = RewardEvent.recordID(completionRecordName: completionName, zoneID: zoneA)
        let idB = RewardEvent.recordID(completionRecordName: completionName, zoneID: zoneB)
        #expect(idA.recordName == idA2.recordName)
        #expect(idA.recordName == idB.recordName)
        #expect(idA.recordName == "reward-completion-123")

        let other = RewardEvent.recordID(completionRecordName: "completion-999", zoneID: zoneA)
        #expect(idA.recordName != other.recordName)
    }

    @Test
    func `payout and rt ledger recordNames are stable and zone independent`() {
        let periodName = "period-fam1-hero1-1234567890"
        let payoutName = "payout-\(periodName)"
        let rtName = "rt-\(periodName)"
        #expect(payoutName == "payout-period-fam1-hero1-1234567890")
        #expect(rtName == "rt-period-fam1-hero1-1234567890")

        let zoneA = CKRecordZone.ID(zoneName: "ZoneA", ownerName: "OwnerA")
        let zoneB = CKRecordZone.ID(zoneName: "ZoneB", ownerName: "OwnerB")
        let payoutA = CKRecord.ID(recordName: payoutName, zoneID: zoneA)
        let payoutB = CKRecord.ID(recordName: payoutName, zoneID: zoneB)
        #expect(payoutA.recordName == payoutB.recordName)

        let rtA = CKRecord.ID(recordName: rtName, zoneID: zoneA)
        let rtB = CKRecord.ID(recordName: rtName, zoneID: zoneB)
        #expect(rtA.recordName == rtB.recordName)
        #expect(payoutA.recordName != rtA.recordName)
    }

    // MARK: - Concurrent duplicate eventKey

    @Test
    func `concurrent duplicate eventKey does not double mint`() async throws {
        let zoneID = makeZoneID(name: "ConcurrentZone")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        appState.cacheService = cache
        let family = makeFamily(zoneID: zoneID)
        var hero = makeProfile(zoneID: zoneID)
        hero.family = CKRecord.Reference(recordID: family.id, action: .none)
        await cache.upsertFamily(family)
        await cache.upsertProfile(hero)
        cloudKit.seedMockRecords([family, hero])
        appState.family = family
        appState.familyZoneID = zoneID
        appState.currentProfile = hero
        appState.isZoneOwner = true

        let gemService = GemService(cloudKitService: cloudKit, cacheService: cache, appState: appState)

        let eventKey = "concurrent-dup-key"
        var tasks: [Task<Void, Never>] = []
        for _ in 0 ..< 10 {
            tasks.append(Task { @MainActor in
                _ = try? await gemService.creditGems(amount: 20, to: hero, source: "testSource", eventKey: eventKey)
            })
        }
        for task in tasks {
            _ = await task.value
        }

        let ledgers = cache.fetchGemLedgers(family: family.id.recordName)
        #expect(ledgers.count == 1, "Concurrent duplicate eventKey must collapse to a single ledger row")
        #expect(ledgers.first?.recordName == "gem-hero1-\(eventKey)-testSource")
        let balance = try gemService.balance(for: hero.id.recordName, familyRecordName: family.id.recordName)
        #expect(balance == 20, "Balance must reflect exactly one credit, not double-minted")
    }

    @Test
    func `concurrent duplicate eventKey via withTaskGroup yields exactly one gem credit`() async throws {
        let zoneID = makeZoneID(name: "ConcurrentZone2")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        appState.cacheService = cache
        let family = makeFamily(zoneID: zoneID)
        var hero = makeProfile(zoneID: zoneID)
        hero.family = CKRecord.Reference(recordID: family.id, action: .none)
        await cache.upsertFamily(family)
        await cache.upsertProfile(hero)
        cloudKit.seedMockRecords([family, hero])
        appState.family = family
        appState.familyZoneID = zoneID
        appState.currentProfile = hero

        let gemService = GemService(cloudKitService: cloudKit, cacheService: cache, appState: appState)

        let eventKey = "daily-login-2026-08-19"
        var secondTasks: [Task<Int, Never>] = []
        for _ in 0 ..< 5 {
            secondTasks.append(Task { @MainActor in
                _ = try? await gemService.creditGems(amount: 15, to: hero, source: "dailyLogin", eventKey: eventKey)
                return (try? gemService.balance(for: hero.id.recordName, familyRecordName: family.id.recordName)) ?? 0
            })
        }
        var results: [Int] = []
        for task in secondTasks {
            await results.append(task.value)
        }

        #expect(results.allSatisfy { $0 == 15 })
        #expect(cache.fetchGemLedgers(family: family.id.recordName).count == 1)
    }

    // MARK: - GemService ledger+profile atomic withBatch

    @Test
    func `applyGemDebit persists ledger and profile atomically`() async throws {
        let cache = try CacheService(inMemory: true)
        let zoneID = makeZoneID(name: "AtomicZone")
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        var hero = Profile(
            displayName: "Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            id: heroID
        )
        hero.gems = 100
        await cache.upsertProfile(hero)

        let ledger = GemLedger(
            profileRecordName: heroID.recordName,
            family: familyRef,
            amount: -30,
            source: "shopPurchase",
            sourceDetail: "Golden Crown",
            createdAt: Date(),
            id: GemLedger.purchaseRecordID(profileRecordName: heroID.recordName, itemID: "headwear_golden_crown", eventKey: nil, zoneID: zoneID)
        )
        var debited = hero
        debited.gems = 70

        await cache.applyGemDebit(profile: debited, ledger: ledger)

        let cachedLedger = cache.fetchGemLedger(recordName: ledger.id.recordName, family: "fam1")
        #expect(cachedLedger != nil, "Ledger must be persisted in the atomic batch")
        #expect(cachedLedger?.amount == -30)

        let cachedProfile = cache.fetchProfile(recordName: heroID.recordName, family: "fam1")
        #expect(cachedProfile?.gemsTotal == 70, "Profile gems must be updated in the same atomic batch as the ledger")
    }

    @Test
    func `withBatch does not leave ledger without profile on simulated save failure`() throws {
        let cache = try CacheService(inMemory: true)
        let zoneID = makeZoneID(name: "AtomicFailZone")
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
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
        cache.context?.insert(ProfileCache(from: hero))
        _ = cache.saveContext()

        let ledger = GemLedger(
            profileRecordName: heroID.recordName,
            family: familyRef,
            amount: 25,
            source: "testReward",
            createdAt: Date(),
            id: GemLedger.deterministicRecordID(profileRecordName: heroID.recordName, eventKey: "atomic-fail", source: "testReward", zoneID: zoneID)
        )
        var updated = hero
        updated.gems = 75

        cache.withBatch {
            cache.context?.insert(ProfileCache(from: updated))
            cache.context?.insert(GemLedgerCache(from: ledger))
            cache.context?.rollback()
        }

        let ledgersAfterRollback = cache.fetchGemLedgers(family: "fam1")
        #expect(ledgersAfterRollback.isEmpty, "Simulated save failure must not leave a ledger row without its profile gems update")

        let profileAfterRollback = cache.fetchProfile(recordName: heroID.recordName, family: "fam1")
        #expect(profileAfterRollback?.gemsTotal == 50, "Profile must remain at pre-batch gems when the batch fails")
    }

    // MARK: - LootDropService rollAndCredit respects idempotency

    @Test
    func `lootDrop rollAndCredit respects gem ledger idempotency`() async throws {
        let zoneID = makeZoneID(name: "LootZone")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        appState.cacheService = cache
        let family = makeFamily(zoneID: zoneID)
        var hero = makeProfile(zoneID: zoneID)
        hero.family = CKRecord.Reference(recordID: family.id, action: .none)
        await cache.upsertFamily(family)
        await cache.upsertProfile(hero)
        cloudKit.seedMockRecords([family, hero])
        appState.family = family
        appState.familyZoneID = zoneID
        appState.currentProfile = hero

        let gemService = GemService(cloudKitService: cloudKit, cacheService: cache, appState: appState)

        let drop = LootDrop(gemAmount: 25, description: "Small Gem Pouch", rarity: .common)
        let lootService = LootDropService(gemService: gemService)
        lootService.rollProvider = { _, _ in drop }

        let eventKey = "completion-loot-123"
        let first = await lootService.rollAndCredit(questRarity: .common, streakDays: 0, to: hero, eventKey: eventKey)
        #expect(first == drop)
        let second = await lootService.rollAndCredit(questRarity: .common, streakDays: 0, to: hero, eventKey: eventKey)
        #expect(second == nil)

        let ledgers = cache.fetchGemLedgers(family: "fam1")
        #expect(ledgers.count == 1, "Second rollAndCredit with same eventKey must not create a second ledger row")
        let balance = try gemService.balance(for: hero.id.recordName, familyRecordName: "fam1")
        #expect(balance == 25, "Balance must reflect exactly one loot credit")

        let rejectedRarity: LootDrop? = lootService.rollForLoot(questRarity: .common, streakDays: 0)
        #expect(rejectedRarity != nil)
    }

    @Test
    func `lootDrop rollAndCredit returns nil when roll misses and does not mint`() async throws {
        let zoneID = makeZoneID(name: "LootMissZone")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        appState.cacheService = cache
        let family = makeFamily(zoneID: zoneID)
        var hero = makeProfile(zoneID: zoneID)
        hero.family = CKRecord.Reference(recordID: family.id, action: .none)
        await cache.upsertFamily(family)
        await cache.upsertProfile(hero)
        appState.family = family
        appState.familyZoneID = zoneID
        appState.currentProfile = hero

        let gemService = GemService(cloudKitService: cloudKit, cacheService: cache, appState: appState)

        let lootService = LootDropService(gemService: gemService)
        lootService.rollProvider = { _, _ in nil }

        let result = await lootService.rollAndCredit(questRarity: .common, streakDays: 0, to: hero, eventKey: "miss-key")
        #expect(result == nil)
        #expect(cache.fetchGemLedgers(family: "fam1").isEmpty)
        #expect(try gemService.balance(for: hero.id.recordName, familyRecordName: "fam1") == 0)
    }

    // MARK: - RewardEvent loser phantom cleanup

    @Test
    func `rewardEvent loser phantom is cleaned when claim returns false`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "PhantomZone", ownerName: "Owner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        appState.cacheService = cache

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let hero = Profile(
            displayName: "Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            id: heroID
        )
        let family = Family(name: "Guild", createdBy: heroID, id: CKRecord.ID(recordName: "fam1", zoneID: zoneID))
        await cache.upsertFamily(family)
        await cache.upsertProfile(hero)
        cloudKit.seedMockRecords([family, hero])

        appState.family = family
        appState.currentProfile = hero
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true

        let completionID = CKRecord.ID(recordName: "completion-phantom", zoneID: zoneID)
        let rewardID = RewardEvent.recordID(completionRecordName: completionID.recordName, zoneID: zoneID)

        let existingReward = RewardEvent(
            profile: CKRecord.Reference(recordID: heroID, action: .none),
            questCompletion: CKRecord.Reference(recordID: completionID, action: .none),
            xpAmount: 50,
            goldAmount: 10,
            timestamp: Date(),
            family: familyRef,
            id: rewardID
        )
        cloudKit.seedMockRecords([existingReward])

        let xpService = XPService(cloudKit: cloudKit, cacheService: cache, appState: appState)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService, cacheService: cache, appState: appState)
        let resolver = CKSyncConflictResolver(cacheService: cache, appState: appState)
        let delegate = CKSyncEngineDelegateHandler(conflictResolver: resolver, cacheService: cache, appState: appState)
        let coordinator = CKSyncEngineCoordinator(cloudKitService: cloudKit, delegateHandler: delegate, appState: appState)
        questService.syncCoordinator = coordinator
        let privateConfig = CKSyncEngine.Configuration(
            database: cloudKit.container.privateCloudDatabase,
            stateSerialization: nil,
            delegate: delegate
        )
        coordinator.privateSyncEngine = CKSyncEngine(privateConfig)

        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none),
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
            name: "Phantom Quest",
            id: CKRecord.ID(recordName: "quest-phantom", zoneID: zoneID)
        )
        await cache.upsertQuest(quest)
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

        let credited = try await questService.applyReward(for: quest, to: hero, completion: completion)
        #expect(credited == 0, "Loser must not be credited")

        let phantom = cache.fetchRewardEvent(recordName: rewardID.recordName, family: "fam1")
        #expect(phantom == nil, "Loser must not leave a local RewardEvent row after claim==false")

        #expect(coordinator.pendingUploadCount == 0, "Loser must not enqueue the phantom RewardEvent")
    }
}
